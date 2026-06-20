import time

import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.eu-central-003.backblazeb2.com",
    aws_access_key_id="003410a18b211d00000000001",
    aws_secret_access_key="K003BAWC5NH36hqTFvk4NqeWYGkGiJ8",
)

# First pass - see how many files exist before we wait
paginator = s3.get_paginator("list_objects_v2")
count_before = 0
for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
    count_before += len(page.get("Contents", []))

print(f"WAL files before waiting: {count_before}")

# Wait 30 seconds for archiving to stabilize
print("Waiting 30 seconds for archiving to stabilize...")
time.sleep(30)

# Second pass - count after waiting
count_after = 0
for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
    count_after += len(page.get("Contents", []))

print(f"WAL files after waiting: {count_after}")

# If count is stable (or decreasing), delete all
if count_after <= count_before:
    print("Archiving has stabilized. Deleting all WAL files...")
    all_objects = []
    for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
        all_objects.extend(page.get("Contents", []))

    for obj in all_objects:
        s3.delete_object(Bucket="biggs-dog", Key=obj["Key"])

    print(f"Deleted {len(all_objects)} WAL files")

    # Verify empty
    final_count = 0
    for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
        final_count += len(page.get("Contents", []))

    print(f"Final WAL files remaining: {final_count}")
    if final_count == 0:
        print("SUCCESS - Archive is now empty!")
    else:
        print("WARNING - Some WAL files remain (might be from ongoing archiving)")
else:
    print(f"WARNING: Count increased from {count_before} to {count_after}")
    print("Archiving may still be catching up. Try again in a few moments.")
