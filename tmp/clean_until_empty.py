import time

import boto3

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.eu-central-003.backblazeb2.com",
    aws_access_key_id="003410a18b211d00000000001",
    aws_secret_access_key="K003BAWC5NH36hqTFvk4NqeWYGkGiJ8",
)

paginator = s3.get_paginator("list_objects_v2")


def count_files():
    count = 0
    for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
        count += len(page.get("Contents", []))
    return count


def delete_all():
    all_objects = []
    for page in paginator.paginate(Bucket="biggs-dog", Prefix="cnpg-bookboss/"):
        all_objects.extend(page.get("Contents", []))

    for obj in all_objects:
        s3.delete_object(Bucket="biggs-dog", Key=obj["Key"])

    return len(all_objects)


# Run for up to 5 minutes, trying to stabilize
start_time = time.time()
max_time = 300  # 5 minutes

while time.time() - start_time < max_time:
    count = count_files()
    print(f"[{int(time.time() - start_time)}s] WAL files: {count}")

    if count == 0:
        print("SUCCESS - Archive is empty!")
        break

    # Delete all files
    deleted = delete_all()
    print(f"  Deleted {deleted} files")

    # Wait 10 seconds for any new files from archiving
    time.sleep(10)

# Final check
final_count = count_files()
print(f"\nFinal count: {final_count}")

if final_count == 0:
    print("SUCCESS - WAL archive is now empty!")
else:
    print(f"WARNING - {final_count} files remain (archiving still running)")
    # Delete them anyway
    deleted = delete_all()
    print(f"Force-deleted {deleted} remaining files")

    # One final check
    final_count = count_files()
    print(f"Final count after force delete: {final_count}")
    if final_count == 0:
        print("SUCCESS - Archive is now empty!")
