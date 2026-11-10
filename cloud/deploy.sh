#!/bin/bash
# Creates or updates the cloud publisher in YOUR AWS account (uses the AWS CLI session of this Mac):
# Lambda + roles for EventBridge Scheduler and the upload-only IAM user the Mac app uses.
# Safe to run again; it only updates what already exists. See docs/CLOUD.md.
#   BUCKET=my-media-bucket [REGION=us-east-1] [NAME=trelune] ./cloud/deploy.sh
# NAME prefixes every resource; set the same value in Trelune → Ajustes → Agendamento.
set -euo pipefail
cd "$(dirname "$0")"
if [ -f ../.env ]; then set -a; . ../.env; set +a; fi
REGION="${REGION:-us-east-1}"
NAME="${NAME:-trelune}"
BUCKET="${BUCKET:?Defina BUCKET com o nome do seu bucket S3 de mídia (ex.: BUCKET=meu-bucket ./cloud/deploy.sh)}"
FUNCTION="$NAME-publisher"
LAMBDA_ROLE="$NAME-publisher"
SCHEDULER_ROLE="$NAME-scheduler"
UPLOADER="$NAME-uploader"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FUNCTION_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

role() { # name trust-service policy-json
  if ! aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam create-role --role-name "$1" --description "Trelune cloud publishing" \
      --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$2\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCOUNT\"}}}]}" >/dev/null
    echo "role $1 criada"
  fi
  aws iam put-role-policy --role-name "$1" --policy-name inline --policy-document "$3"
}

role "$LAMBDA_ROLE" lambda.amazonaws.com "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:$REGION:$ACCOUNT:log-group:/aws/lambda/$FUNCTION:*"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::$BUCKET/scheduled/*"},
 {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$BUCKET","Condition":{"StringLike":{"s3:prefix":"scheduled/*"}}},
 {"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::$BUCKET/$NAME/*"},
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:PutParameter"],"Resource":"arn:aws:ssm:$REGION:$ACCOUNT:parameter/$NAME/vault/*"},
 {"Effect":"Allow","Action":["kms:Decrypt","kms:Encrypt","kms:GenerateDataKey"],"Resource":"*","Condition":{"StringEquals":{"kms:ViaService":"ssm.$REGION.amazonaws.com"}}}
]}
JSON
)"
role "$SCHEDULER_ROLE" scheduler.amazonaws.com "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$FUNCTION_ARN\"}]}"

# The Mac app (upload-only IAM user) also schedules posts and syncs connection tokens.
aws iam get-user --user-name "$UPLOADER" >/dev/null 2>&1 || { aws iam create-user --user-name "$UPLOADER" >/dev/null; echo "usuário $UPLOADER criado"; }
aws iam put-user-policy --user-name "$UPLOADER" --policy-name TreluneUploadOnly --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"UploadMediaOnly","Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::$BUCKET/$NAME/*"},
 {"Sid":"ScheduledPosts","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::$BUCKET/scheduled/*"},
 {"Sid":"ListScheduledPosts","Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$BUCKET","Condition":{"StringLike":{"s3:prefix":"scheduled/*"}}},
 {"Sid":"Schedules","Effect":"Allow","Action":["scheduler:CreateSchedule","scheduler:UpdateSchedule","scheduler:DeleteSchedule","scheduler:GetSchedule"],"Resource":"arn:aws:scheduler:$REGION:$ACCOUNT:schedule/default/po-*"},
 {"Sid":"PassSchedulerRole","Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::$ACCOUNT:role/$SCHEDULER_ROLE"},
 {"Sid":"ConnectionVault","Effect":"Allow","Action":["ssm:GetParameter","ssm:PutParameter"],"Resource":"arn:aws:ssm:$REGION:$ACCOUNT:parameter/$NAME/vault/*"},
 {"Sid":"VaultKey","Effect":"Allow","Action":["kms:Decrypt","kms:Encrypt","kms:GenerateDataKey"],"Resource":"*","Condition":{"StringEquals":{"kms:ViaService":"ssm.$REGION.amazonaws.com"}}}
]}
JSON
)"

(cd publisher && zip -q -X "$work/publisher.zip" index.mjs)
if aws lambda get-function --function-name "$FUNCTION" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION" --zip-file "fileb://$work/publisher.zip" --region "$REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FUNCTION" --environment "Variables={BUCKET=$BUCKET,VAULT_PATH=/$NAME/vault/,PUBLIC_PREFIX=$NAME/}" --region "$REGION" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION" --region "$REGION"
  echo "Lambda atualizada"
else
  sleep 10 # new IAM roles take a few seconds to be assumable
  aws logs create-log-group --log-group-name "/aws/lambda/$FUNCTION" --region "$REGION" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "/aws/lambda/$FUNCTION" --retention-in-days 30 --region "$REGION"
  aws lambda create-function --function-name "$FUNCTION" --runtime nodejs22.x --architectures arm64 --handler index.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$LAMBDA_ROLE" --zip-file "fileb://$work/publisher.zip" --timeout 900 --memory-size 2048 \
    --environment "Variables={BUCKET=$BUCKET,VAULT_PATH=/$NAME/vault/,PUBLIC_PREFIX=$NAME/}" --description "Publica posts agendados do Trelune" --region "$REGION" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FUNCTION" --region "$REGION"
  echo "Lambda criada"
fi
# A failed run must never be retried automatically: it could publish twice.
aws lambda put-function-event-invoke-config --function-name "$FUNCTION" --maximum-retry-attempts 0 --maximum-event-age-in-seconds 3600 --region "$REGION" >/dev/null
echo "FUNCTION_ARN=$FUNCTION_ARN"
echo "SCHEDULER_ROLE_ARN=arn:aws:iam::$ACCOUNT:role/$SCHEDULER_ROLE"
