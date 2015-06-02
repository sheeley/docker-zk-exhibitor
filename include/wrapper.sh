#/bin/bash -e

# Generates the default exhibitor config and launches exhibitor

MISSING_VAR_MESSAGE="must be set"
DEFAULT_AWS_REGION="us-west-2"
DEFAULT_DATA_DIR="/opt/zookeeper/snapshots"
DEFAULT_LOG_DIR="/opt/zookeeper/transactions"
S3_SECURITY=""
HTTP_PROXY=""
BACKUP_EXTRA=""
DEFAULT_EXHIBITOR_PORT="8181"
DEFAULT_EXHIBITOR_CONFIG_PATH="/exhibitor/config"

# Exhibitor Options
: ${ZK_EX_PORT:=$DEFAULT_EXHIBITOR_PORT}
: ${CONFIG_TYPE:="s3"}
: ${HOSTNAME:?$MISSING_VAR_MESSAGE}

# Zookeeper directories
: ${ZK_DATA_DIR:=$DEFAULT_DATA_DIR}
: ${ZK_LOG_DIR:=$DEFAULT_LOG_DIR}
: ${ZK_EX_CONFIG_PATH:=$DEFAULT_EXHIBITOR_CONFIG_PATH}

# set up security if needed
if [[ -n ${ZK_PASSWORD} ]]; then
    SECURITY="--security web.xml --realm Zookeeper:realm --remoteauth basic:zk"
    echo "zk: ${ZK_PASSWORD},zk" > realm
fi

# Determine type of shared config to use
if [[ "$CONFIG_TYPE" = "s3" ]]; then
    # Use S3 Shared Config
    : ${S3_BUCKET:?$MISSING_VAR_MESSAGE}
    : ${S3_PREFIX:?$MISSING_VAR_MESSAGE}
    : ${AWS_REGION:=$DEFAULT_AWS_REGION}
    : ${HTTP_PROXY_HOST:=""}
    : ${HTTP_PROXY_PORT:=""}
    : ${HTTP_PROXY_USERNAME:=""}
    : ${HTTP_PROXY_PASSWORD:=""}

    # set up s3 credentials
    if [[ -n ${AWS_ACCESS_KEY_ID} ]]; then
      cat <<- EOF > /opt/exhibitor/credentials.properties
        com.netflix.exhibitor.s3.access-key-id=${AWS_ACCESS_KEY_ID}
        com.netflix.exhibitor.s3.access-secret-key=${AWS_SECRET_ACCESS_KEY}
EOF

      S3_SECURITY="--s3credentials /opt/exhibitor/credentials.properties"
    fi

    # set up HTTP proxy if needed
    if [[ -n $HTTP_PROXY_HOST ]]; then
    cat <<- EOF > /opt/exhibitor/proxy.properties
      com.netflix.exhibitor.s3.proxy-host=${HTTP_PROXY_HOST}
      com.netflix.exhibitor.s3.proxy-port=${HTTP_PROXY_PORT}
      com.netflix.exhibitor.s3.proxy-username=${HTTP_PROXY_USERNAME}
      com.netflix.exhibitor.s3.proxy-password=${HTTP_PROXY_PASSWORD}
EOF

        HTTP_PROXY="--s3proxy=/opt/exhibitor/proxy.properties"
    fi

    BACKUP_EXTRA="throttle\=&bucket-name\=${S3_BUCKET}&key-prefix\=${S3_PREFIX}&max-retries\=4&retry-sleep-ms\=30000"

    EX_ARGS="
    --configtype s3
    --s3config ${S3_BUCKET}:${S3_PREFIX} \
    ${S3_SECURITY} \
    ${HTTP_PROXY} \
    --s3region ${AWS_REGION} --s3backup true"

elif [[ "$CONFIG_TYPE" = "zookeeper" ]]; then
    # Use Zookeeper Shared Config

    : ${ZK_CONNECT:=$MISSING_VAR_MESSAGE}
    : ${ZK_EX_REST_PATH:="/exhibitor/v1/cluster/list"}
    : ${ZK_EX_POLL_MS:="10000"}
    : ${ZK_EX_CONFIG_RETRY:="1000:3"}

    EX_ARGS="
    --configtype zookeeper
    --zkconfigconnect $ZK_CONNECT
    --zkconfigexhibitorpath $ZK_EX_REST_PATH
    --zkconfigexhibitorport $ZK_EX_PORT
    --zkconfigzpath $ZK_EX_CONFIG_PATH
    --zkconfigpollms $ZK_EX_POLL_MS
    --zkconfigretry $ZK_EX_CONFIG_RETRY"

else
    echo "unsupported config type $CONFIG_TYPE"
    exit 1
fi

cat <<- EOF > /opt/exhibitor/defaults.conf
	zookeeper-data-directory=$ZK_DATA_DIR
	zookeeper-install-directory=/opt/zookeeper
	zookeeper-log-directory=$ZK_LOG_DIR
	log-index-directory=$ZK_LOG_DIR
	cleanup-period-ms=300000
	check-ms=30000
	backup-period-ms=600000
	client-port=2181
	cleanup-max-files=20
	backup-max-store-ms=21600000
	connect-port=2888
	backup-extra=$BACKUP_EXTRA
	observer-threshold=0
	election-port=3888
	zoo-cfg-extra=tickTime\=2000&initLimit\=10&syncLimit\=5&quorumListenOnAllIPs\=true
	auto-manage-instances-settling-period-ms=0
	auto-manage-instances=1
EOF

exec 2>&1

# If we use exec and this is the docker entrypoint, Exhibitor fails to kill the ZK process on restart.
# If we use /bin/bash as the entrypoint and run wrapper.sh by hand, we do not see this behavior. I suspect
# some init or PID-related shenanigans, but I'm punting on further troubleshooting for now since dropping
# the "exec" fixes it.

java -jar /opt/exhibitor/exhibitor.jar \
  --port ${ZK_EX_PORT} \
  --defaultconfig /opt/exhibitor/defaults.conf \
  ${EX_ARGS} \
  --hostname ${HOSTNAME} \
  ${SECURITY}
