#!/bin/bash
# Delete everything aws_up.sh created (tag Project=pgaio-bench): terminate the
# instance (its volumes are delete-on-termination), then the security group
# and the key pair, and check that no tagged volume is left.
#   usage: aws_down.sh          (env: REGION)
set -e
REGION=${REGION:-ap-southeast-2}; TAG=pgaio-bench
A="aws --region $REGION --output text"
IDS=$($A ec2 describe-instances --filters Name=tag:Project,Values=$TAG \
        Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId')
if [ -n "$IDS" ]; then
  $A ec2 terminate-instances --instance-ids $IDS >/dev/null
  echo "terminating $IDS ..."
  $A ec2 wait instance-terminated --instance-ids $IDS
fi
for EP in $($A ec2 describe-instance-connect-endpoints --filters Name=tag:Project,Values=$TAG \
              --query 'InstanceConnectEndpoints[?State!=`delete-complete`].InstanceConnectEndpointId'); do
  $A ec2 delete-instance-connect-endpoint --instance-connect-endpoint-id $EP >/dev/null && echo "deleting endpoint $EP"
  while [ "$($A ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids $EP \
             --query 'InstanceConnectEndpoints[0].State' 2>/dev/null)" = delete-in-progress ]; do sleep 10; done
done
EPSG=$($A ec2 describe-security-groups --filters Name=group-name,Values=$TAG-eice --query 'SecurityGroups[0].GroupId')
VMSG=$($A ec2 describe-security-groups --filters Name=group-name,Values=$TAG --query 'SecurityGroups[0].GroupId')
if [ "$EPSG" != None ] && [ -n "$EPSG" ]; then
  # the two groups reference each other: drop the rules, then the groups
  [ "$VMSG" != None ] && $A ec2 revoke-security-group-ingress --group-id $VMSG \
     --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$EPSG}]" >/dev/null 2>&1 || true
  $A ec2 delete-security-group --group-id $EPSG && echo "deleted security group $EPSG"
fi
SG=$VMSG
[ "$SG" != None ] && [ -n "$SG" ] && $A ec2 delete-security-group --group-id $SG && echo "deleted security group $SG"
$A ec2 describe-key-pairs --key-names $TAG >/dev/null 2>&1 && $A ec2 delete-key-pair --key-name $TAG && echo "deleted key pair $TAG"
rm -f "$HOME/.ssh/$TAG.pem" "$HOME/.ssh/$TAG.instance"
LEFT=$($A ec2 describe-volumes --filters Name=tag:Project,Values=$TAG --query 'Volumes[].VolumeId')
[ -n "$LEFT" ] && { echo "WARNING: volumes still exist: $LEFT"; exit 1; }
echo "all pgaio-bench resources deleted in $REGION"
