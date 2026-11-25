# sqc-scheduler development environment: from container build to running a job

This guide builds an ARM64 container with Podman (or Docker) on an Apple Silicon Mac, then builds and runs sqc-scheduler inside it.
At the end, it runs a job all the way to `done` without a quantum computer, using the built-in `dummy` backend.

- Base image: Rocky Linux 10 (linux/arm64)
- Source: `main` of `ohtanim/sqc-scheduler`
- User inside the container: `sqc` (passwordless sudo)
- Install prefix: `SQC_HOME=/home/sqc/.local`

> Stay on ARM64. x86_64 (`--platform linux/amd64`) runs under emulation and builds very slowly.

---

## 1. Directory layout (on the Mac)

```
rocky10/
├── Dockerfile
├── entrypoint.sh
├── compose.yaml
└── shared/                  # mounted at /shared in the container
    └── sqc-scheduler/       # source (git clone)
```

---

## 2. Container files

### Dockerfile

```dockerfile
FROM rockylinux:10

ARG SQC_USER=sqc
ARG SQC_UID=1000
ARG SQC_GID=1000

USER root

# ---- packages ----
RUN dnf install -q -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf groupinstall -q -y "Development Tools" && \
    dnf install -q -y --nodocs \
        wget which cmake gcc g++ gfortran make \
        perl perl-devel nkf \
        openssl openssl-devel boost-devel gmp-devel libsqlite3x-devel libuuid-devel \
        python3-devel python3.12 python3.12-devel pip \
        munge munge-devel \
        openssh-server openssh-clients sudo \
        iproute procps-ng \
        ca-certificates && \
    dnf clean all

# ---- MUNGE (dev only: key is baked into the image) ----
RUN mungekey --create && \
    chown munge:munge /etc/munge/munge.key && \
    chmod 0400 /etc/munge/munge.key

# ---- sshd (listens on 2222) ----
RUN ssh-keygen -A && \
    sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd

# ---- sqc user ----
RUN groupadd -g ${SQC_GID} ${SQC_USER} && \
    useradd -m -u ${SQC_UID} -g ${SQC_GID} -s /bin/bash ${SQC_USER} && \
    usermod -p '*' ${SQC_USER} && \
    echo "${SQC_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${SQC_USER} && \
    chmod 0440 /etc/sudoers.d/${SQC_USER}

USER ${SQC_USER}
WORKDIR /home/${SQC_USER}

# passwordless ssh to localhost (sqc_rpc_client --auth=munge uses ssh)
RUN mkdir -m 700 ~/.ssh && \
    ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 && \
    cp ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys && \
    chmod 600 ~/.ssh/authorized_keys && \
    printf 'Host localhost 127.0.0.1\n  Port 2222\n  StrictHostKeyChecking accept-new\n' > ~/.ssh/config && \
    chmod 600 ~/.ssh/config

# dev-only self-signed certs for the gRPC broker + JWT files
# (sqc_rpc_sched fails to init the "grpc broker" module without them,
#  even when only MUNGE/TCP is used)
RUN D=/home/${SQC_USER}/.local/etc/sqc-scheduler && \
    mkdir -p $D/ca && cd $D && \
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout ca.key -out ca/grpc_ca.crt -subj "/CN=sqc-dev-ca" && \
    openssl req -newkey rsa:2048 -nodes \
        -keyout grpc_server.key -out grpc_server.csr -subj "/CN=localhost" && \
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > san.ext && \
    openssl x509 -req -in grpc_server.csr -CA ca/grpc_ca.crt -CAkey ca.key \
        -CAcreateserial -days 3650 -extfile san.ext -out grpc_server.crt && \
    rm -f grpc_server.csr san.ext && \
    ln -sf grpc_ca.crt ca/$(openssl x509 -hash -noout -in ca/grpc_ca.crt).0 && \
    openssl genpkey -algorithm RSA -out jwt_priv.key && \
    openssl pkey -in jwt_priv.key -pubout -out jwt_pub.key && \
    echo "sqc-dev" > jwt_iss.txt && \
    chmod 0600 ca.key grpc_server.key jwt_priv.key

# rust (installed for the sqc user)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH=/home/${SQC_USER}/.cargo/bin:/home/${SQC_USER}/.local/bin:${PATH} \
    SQC_HOME=/home/${SQC_USER}/.local \
    VCPKG_DEFAULT_TRIPLET=arm64-linux

# ---- entrypoint: start munged + sshd as root, then idle ----
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
```

### entrypoint.sh

```bash
#!/bin/bash
set -e

# MUNGE
mkdir -p /run/munge
chown munge:munge /run/munge
runuser -u munge -- /usr/sbin/munged

# sshd on 2222
/usr/sbin/sshd -p 2222

exec "$@"
```

### compose.yaml

```yaml
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        SQC_UID: "1000"
        SQC_GID: "1000"
    image: sqc-dev:latest
    platform: linux/arm64
    # network_mode: host cannot be combined with userns_mode: keep-id (rootless Podman)
    ports:
      - "30001:30001"   # simple TCP RPC
      - "30002:30002"   # gRPC
    # Podman only: map your Mac user to sqc (uid 1000) so /shared is writable
    # and files created there are owned by you on the Mac side.
    # Remove this line if you use Docker.
    userns_mode: "keep-id:uid=1000,gid=1000"
    user: root            # entrypoint needs root to start munged/sshd
    volumes:
      - ./shared:/shared
    working_dir: /shared/sqc-scheduler
    stdin_open: true
    tty: true
```

---

## 3. Get the source (on the Mac)

```bash
cd rocky10
mkdir -p shared
git clone https://github.com/ohtanim/sqc-scheduler.git shared/sqc-scheduler
```

> `scripts/build-common.sh` falls back to the `x64-linux` vcpkg triplet when `VCPKG_DEFAULT_TRIPLET` is not set.
> The Dockerfile sets `VCPKG_DEFAULT_TRIPLET=arm64-linux`, so the build uses the ARM64 triplet inside this container.

---

## 4. Build the image and start the container (on the Mac)

```bash
podman compose build            # or: docker compose build
podman compose up -d
podman compose ps               # dev should be Up
```

After changing the `Dockerfile`, run `podman compose build --no-cache` or `podman compose up -d --build`.

---

## 5. Enter the container and check it works

```bash
podman compose exec -u sqc dev bash
```

Run every step from here on inside the container as the `sqc` user.

```bash
uname -m                    # aarch64
munge -n | unmunge          # STATUS: Success (0)
ssh 127.0.0.1 true          # returns without asking for a password
echo $SQC_HOME              # /home/sqc/.local
```

---

## 6. Build sqc-scheduler

```bash
cd /shared/sqc-scheduler
./scripts/build-app-sqc-scheduler.sh
```

The script builds the dependencies in order (cpprestsdk, minio-cpp and libzippp via vcpkg, gRPC, and so on), so the first build takes a while.

Check that the build produced the binaries:

```bash
ls $SQC_HOME/bin/sqc_rpc_sched $SQC_HOME/bin/sqc_rpc_client
```

To rebuild only some parts:

```bash
./scripts/build-rex-apis.sh
./scripts/build-sqc-rpc-sched.sh
```

---

## 7. Create the database and register a user

```bash
cd /shared/sqc-scheduler
./scripts/db-create.sh
./scripts/db-util.sh user add sqc general enable
./scripts/db-util.sh user_group add sqc default enable
./scripts/db-util.sh user_group list         # should show sqc|default|2|...
```

- With MUNGE authentication, the `user_id` is the local account name (`sqc`).
- `user add` alone does not put the user in a group. Also run `user_group add`.
- If you change the database while the server is running, restart the server. It reads the database at startup.
- Optionally, `./scripts/db-util.sh user set role_type sqc admin` makes `sqc` an administrator.

---

## 8. Run a job on the dummy backend (no quantum computer)

### Terminal 1: server

```bash
podman compose exec -u sqc dev bash
cd /shared/sqc-scheduler
export SQC_LOG_FILE=~/sqc-scheduler.log
$SQC_HOME/bin/sqc_rpc_sched 0.0.0.0:30001 0.0.0.0:30002 dummy
```

### Terminal 2: check the server and submit a job

```bash
podman compose exec -u sqc dev bash

ss -ltn | grep -E '3000[12]'                # 30001 and 30002 in LISTEN
grep "ready to go" ~/sqc-scheduler.log       # All the modules are started and ready to go.

cat > /tmp/sample.qasm <<'EOF'
OPENQASM 3;
include "stdgates.inc";
qubit[2] q;
bit[2] c;
h q[0];
cx q[0], q[1];
c = measure q;
EOF

export SQC_RPC_SERVER=127.0.0.1:30001        # use 127.0.0.1, not localhost
$SQC_HOME/bin/sqc_rpc_client submit --auth=munge --remark='dummy test' dummy 2 /tmp/sample.qasm qasm 1000
$SQC_HOME/bin/sqc_rpc_client status --auth=munge <JOB_ID>
```

The job succeeded if it shows `status: 4 (done)` with a result.
Putting `fail` in `--remark` makes the job end in an error on purpose.

The `submit` arguments are, in order: QC type, priority (0-9), circuit file, format (`qasm`), and number of shots.
The QC type must match the one the server was started with.

---

## 9. Stop and clean up

```bash
pkill sqc_rpc_sched                 # in the container: stop the server
exit

podman compose stop                 # on the Mac: stop the container (keeps its contents)
podman compose start                # resume
podman compose down                 # remove the container
```

> **`down` also deletes the build output and the database under `/home/sqc/.local`.** The source in `/shared` is kept.
> After recreating the container, start again from step 6 (build) and step 7 (database).

---

## 10. Problems we hit and how we fixed them

| Symptom | Cause | Fix |
|---|---|---|
| vcpkg fails with `unable to detect the active compiler's information` for `x64-linux` | `build-common.sh` falls back to `x64-linux` when `VCPKG_DEFAULT_TRIPLET` is not set | `export VCPKG_DEFAULT_TRIPLET=arm64-linux` (the Dockerfile sets it) |
| `bash: which: command not found` | The image has no `which` | Added `which` to the Dockerfile |
| `crun: mount sysfs to sys: Operation not permitted` | Rootless Podman with both `network_mode: host` and `userns_mode: keep-id` | Publish ports with `ports:` instead |
| `create-munge-key: No such file or directory` | MUNGE 0.5.14 and later use `mungekey` | `mungekey --create` |
| ss shows no 30001/30002; the log says `Failed to open the file: .../grpc_ca.crt` | Without the gRPC certificates, the server does not start correctly | The Dockerfile now creates dev-only self-signed certificates |
| `openssl: command not found` while building the image | `openssl-devel` does not include the command | Also install the `openssl` package |
| `Failed to connect the socket` from the client | `localhost` resolves to `::1`, but port 30001 listens on IPv4 only | `SQC_RPC_SERVER=127.0.0.1:30001` |
| `User is not in the specified group` | `user add` alone does not put the user in a group | `db-util.sh user_group add sqc default enable`, then restart the server |
| `rqc-rest` ends in `status: 6 (error)` with `Failed to calculate: -2` in the log | `RQC_REST_BASE_URL` in `rest_invoker.c` is still the dummy value | Set the real URL and token and rebuild. For testing, use `dummy` |
| `Unexpected qc-type` | The QC type in `submit` differs from the one the server was started with | Use the same QC type for both |
