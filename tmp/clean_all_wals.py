import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.eu-central-003.backblazeb2.com",
    aws_access_key_id="003410a18b211d00000000001",
    aws_secret_access_key="K003BAWC5NH36hqTFvk4NqeWYGkGiJ8",
)

# List ALL objects under cnpg-bookboss prefix (including subdirectories)
paginator = s3.get_paginator("list_objects_v2")
all_objects = []

for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
    all_objects.extend(page.get("Contents", []))

if not all_objects:
    print("No WAL files found - bucket is clean")
else:
    print(f"Found {len(all_objects)} WAL files to delete")
    for obj in all_objects[:20]:
        print(f"  {obj['Key']}")

    if len(all_objects) > 20:
        print(f"  ... and {len(all_objects) - 20} more")

    # Delete all objects
    for obj in all_objects:
        s3.delete_object(Bucket="biggs-dog", Key=obj["Key"])

    print(f"Deleted {len(all_objects)} WAL files successfully")
