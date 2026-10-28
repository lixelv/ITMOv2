# Test Server: Ubuntu with systemd as PID 1, sshd and optionally Docker.
# Run privileged with a cgroup namespace so systemd and dockerd work under OrbStack.
FROM ubuntu:24.04
ARG WITH_DOCKER=1
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv openssh-server sudo python3 iproute2 procps ca-certificates \
 && if [ "$WITH_DOCKER" = 1 ]; then apt-get install -y --no-install-recommends docker.io; fi \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl enable ssh \
 && useradd -m -s /bin/bash -G sudo tester \
 && echo 'tester:tester' | chpasswd \
 && mkdir -p /home/tester/.ssh && chmod 700 /home/tester/.ssh && chown tester:tester /home/tester/.ssh \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# A known service on a known port for the ports/Process checks.
RUN printf '[Unit]\nDescription=test http\n[Service]\nExecStart=/usr/bin/python3 -m http.server 8765 --bind 0.0.0.0\n[Install]\nWantedBy=multi-user.target\n' \
      > /etc/systemd/system/test-http.service \
 && systemctl enable test-http
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
