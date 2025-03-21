# Redpanda Iceberg Demo with Nessie and Dremio

This demo shows how to install and configure Minio, Redpanda, Nessie and Dremio, enabling SQL access to Iceberg tables
that are populated in realtime through Redpanda topics.

Once the process is completed, the services should be available the following addresses:

- Minio: http://local-minio.minio.svc.cluster.local:9001/login
- Nessie: http://nessie.nessie.svc.cluster.local:19120/
- Redpanda Console: http://redpanda-console.redpanda.svc.cluster.local:8080/
- Dremio: http://dremio-client.dremio.svc.cluster.local:9047/

If your Kubernetes environment doesn't allow to access services directly (shout out to Orbstack!), create port forwards as follows:

```zsh
kubectl port-forward -n minio service/local-minio 9001:9001 &
kubectl port-forward -n nessie service/nessie 19120:19120 &
kubectl port-forward -n redpanda service/redpanda-console 8080:8080 &
kubectl port-forward -n dremio service/dremio-client 9047:9047 &
```

Once the forwards are in place, the services will be available as follows:

- Minio: http://localhost:9001/login
- Nessie: http://localhost:19120/
- Redpanda Console: http://localhost:8080/
- Dremio: http://localhost:9047/

---

# Install Process

## Install Minio

Firstly, create a namespace, install Minio using Helm and extract the credentials:

```zsh
kubectl create namespace minio
helm install -n minio local oci://registry-1.docker.io/bitnamicharts/minio

export ROOT_USER=$(kubectl get secret --namespace minio local-minio -o jsonpath="{.data.root-user}" | base64 -d)
export ROOT_PASSWORD=$(kubectl get secret --namespace minio local-minio -o jsonpath="{.data.root-password}" | base64 -d)

cat << EOF > minio-creds
access=${ROOT_USER}
secret=${ROOT_PASSWORD}
EOF
```

Minio should now be up and running at http://local-minio.minio.svc.cluster.local:9001/login, and you can log in using the credentials stored in `minio-creds`.

### Create Buckets

Next, configure the Minio CLI to have an alias, and use that to create the buckets we will need:
```zsh
export MINIO_POD=$(kubectl get pods -n minio | tail -1 | awk '{print $1}')

kubectl exec -n minio ${MINIO_POD} -- mc alias set local http://local-minio.minio.svc.cluster.local:9000 ${ROOT_USER} ${ROOT_PASSWORD}
kubectl exec -n minio ${MINIO_POD} -- mc mb local/redpanda
kubectl exec -n minio ${MINIO_POD} -- mc mb local/dremio
```

## Install Nessie

Nessie is an Iceberg REST catalog. In this demo, we'll configure Nessie to store it's metadata in Postgresql, but there
are plenty of other options you could consider.

### Install Postgres via Helm (for Nessie)
```zsh
kubectl create namespace nessie
helm install -n nessie local oci://registry-1.docker.io/bitnamicharts/postgresql
```
### Create the Nessie Database and User
```zsh
export POSTGRES_PASSWORD=$(kubectl get secret --namespace nessie local-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
cat resources/create-nessie-db.sql | kubectl exec -it local-postgresql-0 -n nessie -- /opt/bitnami/scripts/postgresql/entrypoint.sh /bin/bash -c "psql postgresql://postgres:${POSTGRES_PASSWORD}@local-postgresql/postgres"

cat << EOF > nessie-db-creds
postgres_username=nessie
postgres_password=nessie123
EOF
```

### Install Nessie Helm Chart

```zsh
kubectl create secret generic postgres-creds --from-env-file="$PWD/nessie-db-creds" -n nessie
kubectl create secret generic minio-creds --from-env-file="$PWD/minio-creds" -n nessie

helm repo add nessie-helm https://charts.projectnessie.org
helm repo update

cat << EOF | helm install -n nessie nessie nessie-helm/nessie \
-f -
versionStoreType: JDBC
jdbc:
  jdbcUrl: jdbc:postgresql://local-postgresql:5432/nessie?currentSchema=nessie
  secret:
    name: postgres-creds
    username: postgres_username
    password: postgres_password
catalog:
  enabled: true
  iceberg:
    defaultWarehouse: warehouse
    warehouses:
    - name: warehouse
      location: s3://redpanda/
    objectStoresHealthCheckEnabled: true
  storage:
    s3:
      defaultOptions:
        region: local
        endpoint: http://local-minio.minio.svc.cluster.local:9000/
        pathStyleAccess: true
        authType: STATIC
        accessKeySecret:
          name: minio-creds
          awsAccessKeyId: access
          awsSecretAccessKey: secret
EOF
```

## Install Redpanda

```zsh
helm repo add redpanda https://charts.redpanda.com
helm repo update

cat << EOF | helm install redpanda redpanda/redpanda \
  --version 5.9.21 \
  --namespace redpanda \
  --create-namespace \
  -f -
image:
  repository: docker.redpanda.com/redpandadata/redpanda-unstable
  tag: v25.1.1-rc2
external:
  service:
    enabled: false
statefulset:
  replicas: 1
service:
  internal:
    annotations:
      prometheus.io/scrape: 'true'
      prometheus.io/path: '/metrics'
      prometheus.io/port: '9644'
config:
  cluster:
    default_topic_replications: 1
    iceberg_enabled: true
    iceberg_catalog_type: rest
    iceberg_rest_catalog_endpoint: http://nessie.nessie.svc.cluster.local:19120/iceberg
    iceberg_rest_catalog_authentication_mode: none
    iceberg_disable_snapshot_tagging: true
    iceberg_rest_catalog_prefix: main
storage:
  tiered:
    config:
      cloud_storage_enabled: true
      cloud_storage_bucket: redpanda
      cloud_storage_api_endpoint: local-minio.minio.svc.cluster.local
      cloud_storage_api_endpoint_port: 9000
      cloud_storage_disable_tls: true
      cloud_storage_region: local
      cloud_storage_access_key: ${ROOT_USER}
      cloud_storage_secret_key: ${ROOT_PASSWORD}
      cloud_storage_segment_max_upload_interval_sec: 30
      cloud_storage_url_style: path
      cloud_storage_enable_remote_write: true
      cloud_storage_enable_remote_read: true
tls:
  enabled: false
EOF
```

## Install Dremio

Clone the Dremio cloud tools, create a namespace and install via Helm.

### Install Dremio Helm Chart

```zsh
git clone https://github.com/dremio/dremio-cloud-tools.git
kubectl create namespace dremio

cat << EOF | helm install dremio dremio-cloud-tools/charts/dremio_v2 -n dremio -f -
zookeeper:
  count: 1
  cpu: 0.1
  memory: 256
coordinator:
  count: 0
  cpu: 2
  memory: 8096
executor:
  count: 1
  cpu: 2
  memory: 4096
distStorage:
  type: "aws"
  aws:
    bucketName: "dremio"
    path: "/"
    authentication: "accessKeySecret"
    credentials:
      accessKey: "${ROOT_USER}"
      secret: "${ROOT_PASSWORD}"
    extraProperties: |
      <property>
        <name>fs.s3a.endpoint</name>
        <value>local-minio.minio.svc.cluster.local:9000</value>
      </property>
      <property>
        <name>fs.s3a.connection.ssl.enabled</name>
        <value>false</value>
      </property>
      <property>
        <name>fs.s3a.path.style.access</name>
        <value>true</value>
      </property>
      <property>
         <name>dremio.s3.compat</name>
        <value>true</value>
      </property>
EOF
```

### Create Nessie Data Source

1. Login to Dremio [directly](http://dremio-client.dremio.svc.cluster.local:9047/) or via a [port forward](http://localhost:9047/). 

2. Register yourself as an admin:

<img src="./images/welcome.png" width="400"/>

3. Next, create a new source:

<img src="./images/add-source.png" width="400"/>

4. Choose Nessie as the type of source:

<img src="./images/choose-nessie.png" width="250"/>

5. On the first page, enter

- `http://nessie.nessie.svc.cluster.local:19120/api/v2` as the Nessie URL
- `None` as the authentication type:

<img src="./images/nessie-page1.png" width="400"/>

6. On the second page, enter:

- `redpanda/redpanda` as the S3 root path
- `admin` as the AWS access key
- The content of `$ROOT_PASSWORD` as the access secret (use `echo ${ROOT_PASSWORD}` to view in your terminal)

For extra parameters, set:

- `fs.s3a.endpoint` to `local-minio.minio.svc.cluster.local:9000`
- `fs.s3a.path.style.access` to `true`
- `dremio.s3.compat` to `true`

And, set `Encrypt Connection` to false.

<img src="./images/nessie-page2.png" width="600"/>

At this point, your infrastructure is ready to go!

---

# Demo

## Create Iceberg Topics in Redpanda

Create a `cars` topic with default partitioning:
```zsh
kubectl cp resources/cars.avsc redpanda-0:/tmp/cars.avsc -n redpanda
kubectl exec redpanda-0 -it -n redpanda -- rpk registry schema create cars-value --schema /tmp/cars.avsc
kubectl exec redpanda-0 -n redpanda -- rpk topic create cars -p1 -r1 --topic-config=redpanda.iceberg.mode=value_schema_id_prefix
```

Create an `events` topic with custom partitioning:
```zsh
kubectl cp resources/events.avsc redpanda-0:/tmp/events.avsc -n redpanda
kubectl exec redpanda-0 -n redpanda -- rpk registry schema create events-value --schema /tmp/events.avsc
kubectl exec redpanda-0 -n redpanda -- rpk topic create events -p1 -r1 -c "redpanda.iceberg.partition.spec=(tenant, day, hour, type)" --topic-config=redpanda.iceberg.mode=value_schema_id_prefix
```

## Publish Messages to Redpanda
```zsh
cat resources/cars.text | kubectl exec -i redpanda-0 -n redpanda -- rpk topic produce cars --schema-id=topic
cat resources/events.text | kubectl exec -i redpanda-0 -n redpanda -- rpk topic produce events --schema-id=topic
```

## Query Iceberg

In Dremio, issue SQL such as `select count(*) from nessie.redpanda.events`:

<img src="./images/query.png" width="800"/>

---

# Other Tools

## Nessie CLI

It's also possible to run the Nessie CLI via Docker to see more detail about your Iceberg tables:

```zsh
docker run --rm -it ghcr.io/projectnessie/nessie-cli:0.103.1
```

Here is an example session:

<img src="./images/nessie-cli.png" width="800"/>


## Parquet Tools

It's also possible to run Parquet tools in Docker, which enables you to see the inner workings such as schemas:

```zsh
# Create a script called pt.sh with the following content:
echo 'docker run --rm -it -v $2:/tmp/file.parquet nathanhowell/parquet-tools $1 /tmp/file.parquet' > pt.sh

# Make the script executable
chmod u+x pt.sh

# Use Parquet Tools for great good!
./pt.sh schema <your local parquet file>
```

For example: 

```text
./pt.sh schema ~/Downloads/-8ac4711b-c5af-496a-9e67-e88686ebf6c5.parquet
Unable to find image 'nathanhowell/parquet-tools:latest' locally
latest: Pulling from nathanhowell/parquet-tools
5843afab3874: Pull complete 
1f07763d5b79: Pull complete 
defbf3670048: Pull complete 
d8fe13e8ceaf: Pull complete 
c82c3a8a8dc8: Pull complete 
Digest: sha256:ad5b0ff79a47d2b758683167abb535265d39c68517642089e76b199b18db9703
Status: Downloaded newer image for nathanhowell/parquet-tools:latest
WARNING: The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8) and no specific platform was requested
message root {
  required group redpanda = 1 {
    required int32 partition (INTEGER(32,true)) = 2;
    required int64 offset (INTEGER(64,true)) = 3;
    required int64 timestamp (TIMESTAMP(MICROS,false)) = 4;
    optional group headers (LIST) = 5 {
      repeated group list {
        required group element = 6 {
          optional binary key = 7;
          optional binary value = 8;
        }
      }
    }
    optional binary key = 9;
  }
  optional binary model (STRING) = 10;
  optional binary make (STRING) = 11;
  optional float year = 12;
}
```
