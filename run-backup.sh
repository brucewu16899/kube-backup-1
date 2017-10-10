#!/bin/sh
set -e

[ -n "$DEBUG" ] && set -x

kubectl=/usr/local/bin/kubectl
jq=jq
backupdir=/tmp/k8s_backup_dir
backuptgz=/tmp/k8s_backup.tgz
kube_restore_file=/tmp/k8s_restore.tgz
kube_restore_dir=/tmp/k8s_restore_dir
dateformat="%Y%m%dT%H%M%SZ"
flagns="backuprestore-donotuse"

# expect our S3TARGET to be in an env var S3TARGET
if [ -z "$S3TARGET" ]; then
  echo "Must provide env variable S3TARGET where to backup to / restore from data"
  echo "Format should be s3://<bucket>/"
  echo "filename will be 'backup_<ISOdate>.tgz' to filename, e.g. backup_20170927T031800Z.tgz"
  echo
  exit 1
fi

if [ "$FREQUENCY" -ne "$FREQUENCY" ] 2>/dev/null; then
  echo "Must provide env variable FREQUENCY as a positive integer for backup frequency in minutes"
  echo
  exit 1
fi

if [ "$MAXRESTOREAGE" -ne "$MAXRESTOREAGE" ] 2>/dev/null; then
  echo "Must provide env variable MAXRESTOREAGE as a positive integer for maximum age of a backup in minutes to allow restore"
  echo
  exit 1
fi

# do we have a custom URI?
aws=
if [ -n "$ENDPOINT_URI" ]; then
  aws="aws --endpoint-url $ENDPOINT_URI"
else
  aws=aws
fi

# strip trailing / off of S3TARGET
s3target_stripped=${S3TARGET%/}


##############
#
# first check for a restore
#
##############
# do we have a backuprestore in place?
set +e
$kubectl get ns $flagns >/dev/null 2>&1
success=$?
set -e

if [ $success -eq 0 ]; then
  echo "restore namespace flag already exists, not restoring"
else
  # get our most recent backup
  set +e
  allBackups=$($aws s3 ls ${s3target_stripped} --recursive)
  success=$?
  set -e

  # did we succeed?
  if [ $success -ne 0 ]; then
    echo "Failed to connect to s3 to retrieve backups. Command was:"
    echo "   $aws s3 ls ${s3target_stripped} --recursive"
    echo
    echo "Check that network connection is good, bucket exists, IAM permissions are correct"
    echo "This is NOT an indication that there are no backups, but that we had an S3 connection error"
    exit 1
  fi
  recentbackup=$(echo "$allBackups" | awk '{print $4}' | sort -nr | head -1)
  # did we have a most recent one?
  if [ -z "$recentbackup" ]; then
    echo "No recent backup to restore"
  else
    echo "Found backup $recentbackup"
    # what is the date of the most recent backup?
    backup_filename=${recentbackup%.tgz}
    backup_date=${backup_filename#backup_}
    # now convert the date to epoch seconds
    # first need a format that "date" command can work with, which is non-standard
    backup_date=$(date --date="$backup_date" -D "$dateformat" +%s)
    # our current date in epoch seconds
    now=$(date +%s)
    # now we can get our age
    backupage=$(( ($now - $backup_date) / 60))
    # see if it is older than our safety net
    if [ "$backupage" -gt "$MAXRESTOREAGE" ]; then
      echo "Backup found but is older than $MAXRESTOREAGE minutes, not restoring"
      exit 1
    else
      $aws s3 cp ${s3target_stripped}/$recentbackup $kube_restore_file
      mkdir -p $kube_restore_dir
      # extract it into the restore dir
      tar -zxf $kube_restore_file -C $kube_restore_dir
      /bin/rm -f $kube_restore_file
      for i in ${kube_restore_dir}/*.json; do
        $kubectl apply -f ${i}
      done
      /bin/rm -rf $kube_restore_dir $kube_restore_file

    fi
  fi
fi

# now we no longer need to restore
$kubectl create ns $flagns >/dev/null 2>&1


##############
#
# set regularly scheduled backups
#
##############


while true ; do
  # wait the specified time
  sleep $(( $FREQUENCY * 60 ))

  # get rid of any older backup files
  /bin/rm -rf $backupdir $backuptgz
  mkdir -p $backupdir

  # output files - it is *really* important that the namespace file be first in sort order
  nsfile=${backupdir}/00-ns.json
  dumpfile=${backupdir}/01-dump.json

  # excluded namespaces
  EXCLUDENS="kube-system"

  $kubectl get --export -o=json ns | \
  $jq --arg excludes "$EXCLUDENS" '
          def inarray($val;ary): ary | any(. == $val);
          def notinarray($val;ary): ary | all(. != $val);
          .items[] | select(notinarray(.metadata.name;($excludes | split(" ")) ) )  |
  	del(.status,
          .metadata.uid,
          .metadata.selfLink,
          .metadata.resourceVersion,
          .metadata.creationTimestamp,
          .metadata.generation
      )' > $nsfile

  namespaces=$(cat $nsfile | $jq -r '.metadata.name');

  for ns in $namespaces; do
      echo "Namespace: $ns"
      $kubectl --namespace="${ns}" get --export -o=json svc,ingress,rc,secrets,configmap,deployment,ds,statefulset | \
      $jq '.items[] |
          select(.type!="kubernetes.io/service-account-token") |
          del(
              .spec.clusterIP,
              .metadata.uid,
              .metadata.selfLink,
              .metadata.resourceVersion,
              .metadata.creationTimestamp,
              .metadata.generation,
              .status,
              .spec.template.spec.securityContext,
              .spec.template.spec.dnsPolicy,
              .spec.template.spec.terminationGracePeriodSeconds,
              .spec.template.spec.restartPolicy
          )' >> "$dumpfile"
  done

  tar czf ${backuptgz} -C ${backupdir} .

  # backup complete, now just upload to S3
  date=$(date --utc +"$dateformat")
  $aws s3 cp $backuptgz ${s3target_stripped}/backup_${date}.tgz

  /bin/rm -rf $backupdir $backuptgz

  # and upload complete, we are done
  echo "Backup complete at" $(date)
done
