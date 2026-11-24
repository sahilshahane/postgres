#!/bin/bash
# SSH to the benchmark VM from a network that blocks outgoing port 22 (e.g.
# a campus proxy): create an EC2 Instance Connect Endpoint (free) in the VM's
# subnet. SSH then tunnels over HTTPS (443):
#   ssh -i ~/.ssh/pgaio-bench.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --region ap-southeast-2 --instance-id %h' ubuntu@<instance-id>
# The VM's security group allows port 22 only from the endpoint's security
# group, not from any internet address. aws_down.sh deletes the endpoint.
#   usage: aws_eice.sh          (env: REGION)
set -e
REGION=${REGION:-ap-southeast-2}; TAG=pgaio-bench
A="aws --region $REGION --output text"
read -r ID _ < "$HOME/.ssh/$TAG.instance"
VPC=$($A ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')
SUBNET=$($A ec2 describe-instances --instance-ids $ID --query 'Reservations[0].Instances[0].SubnetId')
VMSG=$($A ec2 describe-security-groups --filters Name=group-name,Values=$TAG --query 'SecurityGroups[0].GroupId')
EPSG=$($A ec2 describe-security-groups --filters Name=group-name,Values=$TAG-eice --query 'SecurityGroups[0].GroupId')
if [ "$EPSG" = None ] || [ -z "$EPSG" ]; then
  EPSG=$($A ec2 create-security-group --group-name $TAG-eice --vpc-id $VPC \
           --description "pgaio EC2 Instance Connect Endpoint" \
           --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$TAG}]" --query GroupId)
  $A ec2 authorize-security-group-egress --group-id $EPSG \
     --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$VMSG}]" >/dev/null
  $A ec2 authorize-security-group-ingress --group-id $VMSG \
     --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$EPSG}]" >/dev/null
fi
EP=$($A ec2 create-instance-connect-endpoint --subnet-id $SUBNET --security-group-ids $EPSG \
       --tag-specifications "ResourceType=instance-connect-endpoint,Tags=[{Key=Project,Value=$TAG}]" \
       --query 'InstanceConnectEndpoint.InstanceConnectEndpointId')
echo "endpoint $EP creating (takes ~3-5 min); then:"
echo "ssh -i ~/.ssh/$TAG.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --region $REGION --instance-id %h' ubuntu@$ID"
