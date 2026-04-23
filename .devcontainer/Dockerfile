FROM ros:kilted-ros-base

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=ubuntu
ARG USER_UID=1000
ARG USER_GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    locales \
    ca-certificates \
    curl \
    sudo \
    git \
    iproute2 \
    nftables \
    build-essential \
    cmake \
    python3-pip \
    python3-venv \
    python3-setuptools \
    python3-wheel \
    python3-flake8 \
    python3-pytest \
    python3-yaml \
    clang-format \
    clang-tidy \
    cpplint \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-vcstool \
    docker.io \
    docker-buildx \
    docker-compose-v2 \
    ros-kilted-rmw-zenoh-cpp \
    ros-kilted-diagnostic-updater \
    ros-kilted-diagnostic-msgs \
    ros-kilted-diagnostic-aggregator \
    ros-kilted-rqt \
    ros-kilted-rqt-robot-monitor \
    ros-kilted-foxglove-bridge \
    ros-kilted-behaviortree-cpp \
    ros-kilted-nav2-behavior-tree \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US en_US.UTF-8 && \
    update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN if id -u "${USERNAME}" >/dev/null 2>&1; then \
            usermod -aG sudo "${USERNAME}"; \
            if getent group docker >/dev/null 2>&1; then usermod -aG docker "${USERNAME}"; fi; \
    else \
      groupadd --gid "${USER_GID}" "${USERNAME}" && \
      useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/bash "${USERNAME}" && \
            usermod -aG sudo "${USERNAME}"; \
            if getent group docker >/dev/null 2>&1; then usermod -aG docker "${USERNAME}"; fi; \
    fi && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" && \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

RUN printf '#!/usr/bin/env bash\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose && \
        chmod +x /usr/local/bin/docker-compose

RUN echo "source /opt/ros/kilted/setup.bash" >> /etc/bash.bashrc && \
    echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /etc/bash.bashrc && \
    echo "export ROS_DOMAIN_ID=42" >> /etc/bash.bashrc

WORKDIR /workspaces/ws_link_assurance_demo
USER ${USERNAME}
