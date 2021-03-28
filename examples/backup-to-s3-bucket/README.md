How to backup piler enterprise data to an S3 bucket

## Prerequisites

* Have an S3 compatible object store either in the cloud or using minio on premise
* Get the minio client from [https://min.io/download#/linux](https://min.io/download#/linux)
* Create a config to your bucket using mc alias

Fix the BUCKET_PREFIX variable in backup-to-s3.sh script, eg.

```
### Make sure, your bucket prefix is unique especially when using a cloud provider
BUCKET_PREFIX="s3/your-bucket-prefix"
```

## Create a cron entry for user piler

```
50 3 * * * /usr/local/bin/backup-to-s3.sh
```

## Notes

The script copies only the last 2 top level store folders (eg. /var/piler/store/00/piler/605) to the S3 bucket.
For the first use be sure to fix the store level dir in the 125th line to make sure all store data is copied.

```
backup_customer_dir "$customer" "$STORE_DIR" "store" 200
```

After the first run, you may revert it to "2", because older directories don't change.

The backup script appends the customer name to the prefix, eg. s3/company-name-piler-backup-${customer}
