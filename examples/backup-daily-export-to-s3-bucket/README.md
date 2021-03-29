How to backup piler enterprise data to an S3 bucket

The below script uploads the daily exported emails encrypted.

Pros:
* You only upload one day (=the previous day) of emails at one time

Cons:
* When restoring you need to start from scratch, and the import takes a while

## Prerequisites

* Have an S3 compatible object store either in the cloud or using minio on premise
* Get the minio client from [https://min.io/download#/linux](https://min.io/download#/linux)
* Create a config to your bucket using mc alias

### Create the encryption key

```
openssl rand -hex 64 > /etc/piler/backup.key
chown piler:piler /etc/piler/backup.key
chmod 600 /etc/piler/backup.key
```

Fix the BUCKET_PREFIX variable in backup-daily-export-to-s3.sh script, eg.

```
### Make sure, your bucket prefix is unique especially when using a cloud provider
BUCKET_PREFIX="s3/your-bucket-prefix"
```

## Create a cron entry for user piler

```
50 3 * * * /usr/local/bin/backup-daily-export-to-s3.sh
```

## Notes

The backup script appends the customer name to the prefix, eg. s3/company-name-piler-backup-${customer}.

Be sure to backup the encryption key, otherwise your backup is as good as gone.
