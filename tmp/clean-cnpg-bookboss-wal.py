import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.eu-central-003.backblazeb2.com",
    aws_access_key_id="003410a18b211d00000000001",
    aws_secret_access_key="K003BAWC5NH36hqTFvk4NqeWYGkGiJ8",
)

bucket = "biggs-dog"
prefix = "cnpg-bookboss/"

# Count before
objects = list(s3.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", []))
print(f"Objects before cleanup: {len(objects)}")

# Delete all
for obj in objects:
    s3.delete_object(Bucket=bucket, Key=obj["Key"])

# Verify empty
remaining = s3.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", [])
print(f"Objects after cleanup: {len(remaining)}")
print("Done")
