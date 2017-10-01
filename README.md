# kube-backup
This is a basic project to backup and restore (almost) everything in your [kubernetes](https://kubernetes.io) cluster. Backups are kept in an S3 bucket.

This predates some of the more advanced and full-features backup systems such as [ark](https://github.com/heptio/ark) but is in use in a number of deployments.


### How It Works
It runs as a `kube-system` namespace deployment with exactly one replica.

It works as follows. On container startup, it first checks if it needs to perform a restore, and then goes into regular backup mode.

### Restore
On startup, the container checks the following:

* Does a namespace named "backuprestore-donotuse" exist?
* Are there previous backups available?

1. If the namespace already exists, then we already have run a restore on this cluster - or there was none available - so do not perform any restore.
2. If the namespace does not exist but there are no backups available, then we have nothing to restore.
3. If the namespace does not exist and there are backups, but they are "stale", i.e. older than a specific age, error out.
4. If the namespace does not exist and there is at least one non-stale backup, perform a restore.

#### Backup
Backup runs in an infinite loop. Every configurable set of minutes:

1. Dump a list of all of the namespaces _except_ `kube-system`
2. Dump all of the item types in the list below
3. Filter the data to exclude anything specific to this cluster, e.g. cluster-allocated IPs
4. Zip Everything up
5. Name it `backup_YYYYMMDDTHHMMSSZ` where time is in UTC
6. Upload to S3

The backed up items are as follows:

* `Service`
* `Ingress`
* `ReplicaSet`
* `Secret`
* `ConfigMap`
* `Deployment`
* `DaemonSet`
* `StatefulSet`

### No kube-system
We do **not** back up anything in kube-system. We assume that your cluster setup is configured to install all kube-system elements as part of initialization and therefore does not need to be backed up.

We are aware that this is an opinionated way to build clusters, but it works for us.


### Configuration
The following environment variables are passed to the deployment:

* `S3TARGET`: REQUIRED. An S3 URL, consumable by the `aws s3` CLI, that indicates a bucket to which to save the data and from which to restore it.
* `FREQUENCY`: REQUIRED. How often, in minutes, to run backup. Must be a positive integer.
* `MAXRESTOREAGE`: REQUIRED. Maximum age, in minutes, between the time a backup was created and a restore is run for a backup not to be considered "stale".
* `AWS_ACCESS_KEY_ID`: OPTIONAL. AWS access key to use for S3. If you do not need an access key - e.g. if you are running on an EC2 node with appropriate roles - then do not pass this.
* `AWS_SECRET_ACCESS_KEY`: OPTIONAL. AWS secret access key to use for S3. If you do not need an access key - e.g. if you are running on an EC2 node with appropriate roles - then do not pass this.
* `ENDPOINT_URI`: OPTIONAL. If you want to point the S3 upload to a distinct URI.
* `DEBUG`: OPTIONAL. Set to "true" to enable debug messaging.

### Deployment
To deploy:

1. Create a kubernetes `secret` in the `kube-system` namespace with the environment variables listed above. The `secret` must be named `kube-backup`. A sample is included.
2. Use the kubernetes configuration file in this repository: `kubectl apply -f kube-backup.yml`

## Tests
The tests for this are not yet fully automated, because they require a cluster to run.

To run the tests:

1. Ensure your `kubectl` is pointing at a cluster with which you are willing to work.
2. `make test`: will do the following:
    1. clean out any flag namespace
    2. start [minio](https://minio.io) in a deployment
    3. start some sample `nginx` services
    4. set up a `secret` for `kube-backup` to access `minio`, with backups configured to run every 180 seconds
    5. deploy the backup service standard [kube-backup.yml](./kube-backup.yml)
    6. Wait enough time for the backups to run
    7. scale _down_ the backup service to preserve the last backup
    8. Remove all of the `nginx` services added and test namespace
    9. Remove the flag namespace
    10. scale _up_ the backup services, which should restore everything in [test/services.yml](./test/services.yml)
    11. Output all items with the label `test=backup` to see if they match
