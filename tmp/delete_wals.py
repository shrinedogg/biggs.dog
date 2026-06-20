import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.eu-central-003.backblazeb2.com",
    aws_access_key_id="003410a18b211d00000000001",
    aws_secret_access_key="K003BAWC5NH36hqTFvk4NqeWYGkGiJ8",
)

response = s3.list_objects_v2(Bucket="biggs-dog", Prefix="cnpg-bookboss/")
objects = response.get("Contents", [])

if not objects:
    print("No WAL files found")
else:
    print(f"Found {len(objects)} WAL files to delete")
    for obj in objects[:5]:
        print(f"  {obj['Key']}")

    for obj in objects:
        s3.delete_object(Bucket="biggs-dog", Key=obj["Key"])

    print(f"Deleted {len(objects)} WAL files successfully")
