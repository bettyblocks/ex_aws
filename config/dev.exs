import Config

config :ex_aws,
  debug_requests: true,
  s3_auth_version: [{:system, "S3_AUTH_VERSION"}, :instance_role],
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: "us-east-1"
