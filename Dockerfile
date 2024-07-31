FROM almalinux:9.4

ENV USER_HOME=/home/docker
ENV LANG en_US.UTF-8

# Create docker group/user and disable logins
RUN groupadd --gid 1000 docker \
 && adduser --uid 1000 --gid 1000 --home ${USER_HOME} docker \
 && usermod -L docker

# Ensure locale is UTF-8
RUN dnf install --assumeyes \
    glibc-langpack-en \
    glibc-locale-source \
 && localedef --force --inputfile=en_US --charmap=UTF-8 en_US.UTF-8 \
 && echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Installs ruby module and sets version to 3.0
RUN dnf module enable ruby:3.3 --assumeyes \
 && dnf install --assumeyes \
    ruby \
    ruby-devel \
    gcc-c++ \
    make \
    redhat-rpm-config \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum

# Install EPEL and configure dnf, install updates, common packages, Ruby and clean up dnf's cache
RUN dnf install --assumeyes https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm \
 && dnf install --assumeyes dnf-plugins-core \
 && dnf config-manager --set-enabled powertools \
 && dnf update --assumeyes \
 && dnf install --assumeyes \
    ca-certificates \
    curl \
    wget \
    psmisc \
    procps-ng \
    jq \
 && dnf autoremove --assumeyes \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum


COPY Gemfile Gemfile.lock /app/

WORKDIR /app
USER root
RUN gem install bundler
RUN bundle install

COPY . /app/

#USER default
EXPOSE 4567
CMD /app/app.rb
