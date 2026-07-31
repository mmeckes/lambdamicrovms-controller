#!/usr/bin/env bash
#
# Package a MicroVM application artifact and upload it to Amazon S3.
#
# Artifact packaging is deliberately NOT modelled as a custom resource. Building
# and publishing a zip is a developer and CI concern that happens at the pace of
# code changes; the declarative layer owns the image built FROM that artifact,
# not the artifact itself. See the "Division of responsibility" section of the
# repository README.
#
# Run this from CI on every commit, then either update the MicrovmImage's
# codeArtifact.uri to point at the new object, or overwrite the same key and
# trigger a rebuild. See ../05-lifecycle/ for both approaches.
#
# Usage:
#   ./package-artifact.sh --bucket my-bucket
#   ./package-artifact.sh --bucket my-bucket --key builds/app-$GIT_SHA.zip
#   ./package-artifact.sh --bucket my-bucket --source ./my-app
#
set -euo pipefail

BUCKET=""
KEY="app.zip"
SOURCE=""
REGION="${AWS_REGION:-}"

usage() {
  cat <<'USAGE'
Usage: package-artifact.sh --bucket <name> [options]

Required:
  --bucket <name>   S3 bucket to upload the artifact to

Options:
  --key <path>      Object key for the artifact (default: app.zip)
  --source <dir>    Directory containing your app and Dockerfile.
                    If omitted, a sample Node.js application is generated.
  --region <name>   AWS region (default: $AWS_REGION)
  -h, --help        Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="${2:-}"; shift 2 ;;
    --key)    KEY="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "error: --bucket is required" >&2
  usage >&2
  exit 2
fi

for cmd in aws zip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: '$cmd' is required but not installed" >&2
    exit 1
  fi
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [[ -n "$SOURCE" ]]; then
  if [[ ! -d "$SOURCE" ]]; then
    echo "error: --source directory '$SOURCE' does not exist" >&2
    exit 1
  fi
  if [[ ! -f "$SOURCE/Dockerfile" ]]; then
    echo "error: '$SOURCE/Dockerfile' not found; a Dockerfile is required" >&2
    exit 1
  fi
  echo "==> Packaging from $SOURCE"
  cp -R "$SOURCE"/. "$WORKDIR/"
else
  echo "==> No --source given; generating the sample Node.js application"

  cat > "$WORKDIR/app.js" <<'APP'
// Minimal HTTP server — listens on port 8080.
//
// Snapshot compatibility note: this MicroVM image is created by snapshotting a
// fully initialized process, and every MicroVM launched from it resumes from
// that same snapshot. If your application generates unique values (IDs, secrets,
// cryptographic material), use your language's cryptographically secure
// pseudorandom number generator so those values differ across MicroVMs. If you
// use OpenSSL, prefer the Lambda base container image, which includes a
// snapshot-compatible build.
const http = require('http');
const crypto = require('crypto');

// Generated per MicroVM after resume, not baked into the snapshot.
const instanceId = crypto.randomUUID();

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok', path: req.url, instanceId }));
});

server.listen(8080, () => {
  console.log('Listening on port 8080');
});
APP

  cat > "$WORKDIR/Dockerfile" <<'DOCKERFILE'
# The FROM instruction sets the container image for your application layers.
# The MicroVM operating system and service components come from the Lambda
# managed base image, which is specified separately as baseImageARN on the
# MicrovmImage resource.
FROM node:24-alpine

WORKDIR /app

COPY app.js .

# Declare the port your application listens on.
EXPOSE 8080

# Lambda snapshots the running state of this process.
CMD ["node", "app.js"]
DOCKERFILE
fi

echo "==> Building $WORKDIR/artifact.zip"
(cd "$WORKDIR" && zip -q -r artifact.zip . -x 'artifact.zip')

DEST="s3://$BUCKET/$KEY"
echo "==> Uploading to $DEST"

aws_args=()
if [[ -n "$REGION" ]]; then
  aws_args+=(--region "$REGION")
fi
aws "${aws_args[@]}" s3 cp "$WORKDIR/artifact.zip" "$DEST"

cat <<EOF

==> Done.

Artifact: $DEST

Point a MicrovmImage at it:

  spec:
    codeArtifact:
      uri: $DEST

The build role for that image needs s3:GetObject on:

  arn:aws:s3:::$BUCKET/$KEY
EOF
