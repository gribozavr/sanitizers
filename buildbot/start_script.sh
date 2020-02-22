#!/bin/bash

# Script to configure GCE instance to run sanitizer build bots.

# NOTE: GCE can wait up to 20 hours before reloading this file.
# If some instance needs changes sooner just shutdown the instance 
# with GCE UI or "sudo shutdown now" over ssh. GCE will recreate
# the instance and reload the script.

MASTER_PORT=${MASTER_PORT:-9990}
ON_ERROR=${ON_ERROR:-shutdown now}

BOT_DIR=/b

mount -t tmpfs tmpfs /tmp
mkdir -p $BOT_DIR
mount -t tmpfs tmpfs -o size=80% $BOT_DIR

cat <<EOF >/etc/apt/sources.list.d/stretch.list
deb http://deb.debian.org/debian/ stretch main
deb-src http://deb.debian.org/debian/ stretch main
deb http://security.debian.org/ stretch/updates main
deb-src http://security.debian.org/ stretch/updates main
deb http://deb.debian.org/debian/ stretch-updates main
deb-src http://deb.debian.org/debian/ stretch-updates main
EOF

cat <<EOF >/etc/apt/apt.conf.d/99stretch
APT::Default-Release "buster";
EOF

(
  SLEEP=0
  for i in `seq 1 5`; do
    sleep $SLEEP
    SLEEP=$(( SLEEP + 10))

    (
      set -ex
      dpkg --add-architecture i386
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
      dpkg --configure -a
      apt-get -qq -y update
      apt-get -qq -y upgrade

      # Logs consume a lot of storage space.
      apt-get remove -qq -y --purge auditd puppet-agent google-fluentd

      apt-get install -qq -y \
        automake \
        binutils-dev \
        binutils-gold \
        ccache \
        clang-8 \
        cmake \
        curl \
        dos2unix \
        e2fsprogs \
        g++ \
        g++-multilib \
        gawk \
        gcc-multilib \
        git \
        kpartx \
        libc-l10n \
        libctypes-ocaml-dev \
        libgcrypt-dev \
        libgss-dev \
        liblocale-gettext-perl \
        liblzma-dev \
        libounit-ocaml-dev \
        libpam-modules \
        libpam-modules-bin \
        libpam-runtime \
        libpython-dev \
        libssl-dev \
        libtext-charwidth-perl \
        libtext-iconv-perl \
        libtool \
        libxml2-dev \
        locales \
        m4 \
        make \
        mawk \
        ncurses-base \
        ncurses-bin \
        ninja-build \
        ocaml-findlib \
        ocaml-nox \
        opam \
        perl-base \
        pinentry-curses \
        pkg-config \
        procps \
        python \
        python-pip \
        python-psutil \
        python-six \
        python3-psutil \
        readline-common \
        sensible-utils \
        subversion \
        wget \
        
        #python3-distutils \
        #python3-google-compute-engine \
        #unattended-upgrades
        #gnupg-agent \
        #acpi-support-base \
        #ethtool \
        #apt-transport-https \
        #aptitude \
        #iputils-ping \
        #isc-dhcp-client \
        #less \
        #login \
        #logrotate \
        #lsb-base \
        #lsb-release \
        #man-db \
        #mount \
        #nano \
        #net-tools \
        #netbase \
        #ntp \
        #parted \
        #passwd \
        #puppet-agent \
        #rsyslog \
        #screen \
        #sed \
        #task-ssh-server \
        #unattended-upgrades \
        #sudo \
        #vim \
        #vim-nox \
        #python3-buildbot-worker
        #linux-image-amd64
        #auditd
        #google-cloud-packages-archive-keyring
        #google-cloud-sdk
        #google-fluentd
        #google-fluentd-catch-all-config
        #grub-pc
        #htop
        #ifupdown
        #iotop
        #iproute2
        #iptables
        #drawfork-puppet-manifests
        #clang
        #cloud-guest-utils

      for n in 1 2; do
        [[ ! -d $BOT_DIR/$n ]] || buildslave stop $BOT_DIR/$n
      done
      apt-get remove -qq -y --purge buildbot-slave
      apt-get install -qq -y -t stretch buildbot-slave
    ) && exit 0
  done
  exit 1
) || $ON_ERROR

update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.gold" 20
update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.bfd" 10
update-alternatives --install "/usr/bin/clang" "clang" "/usr/bin/clang-8" 10
update-alternatives --install "/usr/bin/clang++" "clang++" "/usr/bin/clang++-8" 10

systemctl set-property buildslave.service TasksMax=100000

chown buildbot:buildbot $BOT_DIR

rm -f /etc/default/buildslave

for n in 1 2; do
buildslave create-slave --allow-shutdown=signal $BOT_DIR/$n lab.llvm.org:$MASTER_PORT "$1" "$2"
shift
shift

echo "Vitaly Buka <vitalybuka@google.com>" > $BOT_DIR/$n/info/admin

{
  uname -a | head -n1
  cmake --version | head -n1
  clang --version | head -n1
  g++ --version | head -n1
  ld --version | head -n1
  date
  lscpu
} > $BOT_DIR/$n/info/host

cat <<EOF >>/etc/default/buildslave
SLAVE_RUNNER=/usr/bin/buildslave
SLAVE_ENABLED[$n]="1"
SLAVE_NAME[$n]="buildslave$n"
SLAVE_USER[$n]="buildbot"
SLAVE_BASEDIR[$n]="$BOT_DIR/$n"
SLAVE_OPTIONS[$n]=""
SLAVE_PREFIXCMD[$n]=""
EOF
done

mkdir -p $BOT_DIR/ccache
chown -R buildbot:buildbot $BOT_DIR
systemctl daemon-reload
service buildslave restart

cat <<EOF >/etc/ccache.conf
max_size = 50G
cache_dir = $BOT_DIR/ccache
EOF

sleep 30
for n in 1 2; do
  cat $BOT_DIR/$n/twistd.log
  grep "slave is ready" $BOT_DIR/$n/twistd.log || $ON_ERROR
done

# GCE can restart instance after 24h in the middle of the build.
# Gracefully restart before that happen.
sleep 72000
while pkill -SIGHUP buildslave; do sleep 5; done;
$ON_ERROR
