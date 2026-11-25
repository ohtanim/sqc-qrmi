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

# ---- sshd (listens on 2222 to avoid clashing with the host's sshd under --net=host) ----
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
