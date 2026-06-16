# MinIO

MinIO — high-performance, S3-compatible object storage. Used as the storage backend for file uploads, assets, and any blob data in the BaaS platform.

## Quick Start

```bash
docker compose up minio
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MINIO_ROOT_USER` | — | Admin access key (required) |
| `MINIO_ROOT_PASSWORD` | — | Admin secret key (required) |
| `MINIO_BROWSER` | `on` | Enable/disable the web console |
| `MINIO_REGION` | `us-east-1` | Default region |

## Ports

| Port | Description |
|------|-------------|
| `9000` | S3-compatible API |
| `9001` | MinIO web console |

## CLI Examples

### Using the MinIO Client (`mc`)

```bash
# Install mc (if not already available)
# brew install minio/stable/mc  # macOS
# or download from https://min.io/docs/minio/linux/reference/minio-mc.html

# Configure alias
mc alias set local http://localhost:9000 <MINIO_ROOT_USER> <MINIO_ROOT_PASSWORD>

# List buckets
mc ls local

# Create a bucket
mc mb local/my-bucket

# Upload a file
mc cp ./myfile.png local/my-bucket/myfile.png

# Download a file
mc cp local/my-bucket/myfile.png ./downloaded.png

# List objects in a bucket
mc ls local/my-bucket

# Make a bucket public
mc anonymous set public local/my-bucket

# Remove a file
mc rm local/my-bucket/myfile.png

# Get bucket info
mc stat local/my-bucket

# Mirror a local directory to a bucket
mc mirror ./uploads local/my-bucket/uploads
```

### Using curl (S3 API)

```bash
# List buckets (requires AWS Signature V4 — easier with mc or aws-cli)
aws --endpoint-url http://localhost:9000 s3 ls

# Upload via aws-cli
aws --endpoint-url http://localhost:9000 s3 cp ./file.txt s3://my-bucket/file.txt

# Download
aws --endpoint-url http://localhost:9000 s3 cp s3://my-bucket/file.txt ./file.txt
```

### Web Console

Open [http://localhost:9001](http://localhost:9001) in your browser and log in with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`.

## Health Check

```bash
curl -sf http://localhost:9000/minio/health/live
```

Returns `200 OK` when MinIO is running. For cluster readiness:

```bash
curl -sf http://localhost:9000/minio/health/ready
```

## Docker

- **Image:** `minio/minio`
- **Ports:** `9000` (API), `9001` (Console)
- **Command:** `server /data --console-address ":9001"`
- **Volumes:** `minio-data:/data`
- **Networks:** Internal `baas` network
