#!/bin/bash
# Launch the benchmark VM on AWS: c6i.2xlarge + 100 GB gp3 data volume
# (6400 IOPS, 125 MB/s) in the default VPC, SSH allowed from this machine's
# public IP only.  Everything is tagged Project=pgaio-bench; aws_down.sh
# deletes it all.
#
# Safety net: the VM powers itself off after MAX_HOURS (default 10) and
# instance-initiated shutdown = terminate, and both volumes are
# delete-on-termination, so a forgotten VM stops costing money by itself.
#
#   usage: aws_up.sh            (env: REGION, AZ, TYPE, IOPS, SIZE_GB, MAX_HOURS)
set -e
REGION=${REGION:-ap-southeast-2}; AZ=${AZ:-ap-southeast-2a}; TYPE=${TYPE:-c6i.2xlarge}
IOPS=${IOPS:-6400}; SIZE_GB=${SIZE_GB:-100}; MAX_HOURS=${MAX_HOURS:-10}
TAG=pgaio-bench; KEY=$HOME/.ssh/$TAG.pem
A="aws --region $REGION --output text"

if [ ! -f "$KEY" ]; then
  $A ec2 create-key-pair --key-name $TAG --key-type ed25519 \
     --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$TAG}]" \
     --query KeyMaterial > "$KEY"
  chmod 600 "$KEY"
fi

VPC=$($A ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')
SG=$($A ec2 describe-security-groups --filters Name=group-name,Values=$TAG Name=vpc-id,Values=$VPC \
       --query 'SecurityGroups[0].GroupId')
if [ "$SG" = None ] || [ -z "$SG" ]; then
  SG=$($A ec2 create-security-group --group-name $TAG --vpc-id $VPC \
         --description "pgaio benchmark: ssh from one IP" \
         --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG}]" --query GroupId)
fi
MYIP=$(curl -s https://checkip.amazonaws.com)
$A ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 \
   --cidr "$MYIP/32" >/dev/null 2>&1 || true      # already allowed is fine

AMI=$($A ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query Parameter.Value)
SUBNET=$($A ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=availability-zone,Values=$AZ \
           Name=default-for-az,Values=true --query 'Subnets[0].SubnetId')

# power off after MAX_HOURS no matter what (-> terminate, volumes deleted)
USERDATA=$(printf '#!/bin/bash\nshutdown -h +%d "pgaio-bench safety net"\n' $((MAX_HOURS * 60)))

ID=$($A ec2 run-instances --image-id $AMI --instance-type $TYPE --key-name $TAG \
      --subnet-id $SUBNET --security-group-ids $SG --associate-public-ip-address \
      --instance-initiated-shutdown-behavior terminate \
      --user-data "$USERDATA" \
      --metadata-options HttpTokens=required \
      --block-device-mappings "[
        {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":20,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
        {\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":$SIZE_GB,\"VolumeType\":\"gp3\",\"Iops\":$IOPS,\"Throughput\":125,\"DeleteOnTermination\":true}}]" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$TAG},{Key=Name,Value=$TAG}]" \
                           "ResourceType=volume,Tags=[{Key=Project,Value=$TAG}]" \
      --query 'Instances[0].InstanceId')
echo "instance $ID launching ($TYPE, $AZ); waiting for it to run..."
$A ec2 wait instance-running --instance-ids $ID
IP=$($A ec2 describe-instances --instance-ids $ID --query 'Reservations[0].Instances[0].PublicIpAddress')
DATAVOL=$($A ec2 describe-instances --instance-ids $ID \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/sdf'].Ebs.VolumeId")
echo "$ID $IP $DATAVOL" > "$HOME/.ssh/$TAG.instance"
echo "running: $ID at $IP, data volume $DATAVOL (auto power-off in $MAX_HOURS h)"
echo "ssh -i $KEY ubuntu@$IP"
echo "data disk on the VM: /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${DATAVOL/-/}"
