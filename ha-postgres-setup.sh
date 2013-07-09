#!/bin/bash
# Set up a HA-cluster with LVM, DRBD, Pacemaker, and pgSQL.
# Based on https://wiki.postgresql.org/images/0/07/Ha_postgres.pdf
# Assumes a basic Ubuntu 12.04 installation and a 2-node setup.
# Also assumes that the disk you want to mirror is 500MB on /dev/sdb.
# Run this script at the same time on both nodes, as root.

# Check we're root
[[ $UID == 0 || $EUID == 0 ]] || (
  echo "Must be root!"
  exit 1
  ) || exit 1

# Get information we will need later
while ! [[ $nodetype == "p" || $nodetype == "s" ]]; do
  echo -n "Is this the primary or secondary node? [p/s]: "
  read nodetype
done

echo -n "Enter the primary node's name: "
read primaryname

echo -n "Enter the primary node's IP: "
read primaryip

echo -n "Enter the secondary node's name: "
read secondaryname

echo -n "Enter the secondary node's IP: "
read secondaryip

echo -n "Enter the broadcast address for the cluster: "
read broadcastip

echo -n "Enter the desired virtual IP for the cluster (must be free!): "
read virtualip

# Install LVM
apt-get install lvm2

# LVM filter for DRBD
sed -i 's/^filter =/filter = [ "r|\/dev\/sdb|", "r|\/dev\/disk\/*|", "r|\/dev\/block\/*|", "a|.*|" ]/g' \
  /etc/lvm/lvm.conf
  
sed -i 's/^write_cache_state = /write_cache_state = 0/g' \
  /etc/lvm/lvm.conf
  
update-initramfs -u
update-initramfs -u -k $(uname -r)

# Install DRBD
apt-get install drbd8-utils
# ...and start the kernel module
modprobe drbd

# Postgres resource
cat << EOF > /etc/drbd.d/pg.res
resource pg {
  device minor 0;
  disk /dev/sdb;
  
  syncer {
    rate 150M;
    verify-alg md5;
  }
  
  on ${primaryname} {
    address ${primaryip}:7788;
    meta-disk internal;
  }
 
  on ${secondaryname} {
    address ${secondaryip}:7788;
    meta-disk internal;
  }
}
EOF

# Disable DRBD on startup, this will be managed by Pacemaker
update-rc.d drbd disable

# Set up the device with the Postgres resource
drbdadm create-md pg
drbdadm up pg

# Start the DRBD service
service drbd start
drbdadm -- --overwrite-data-of-peer primary pg

cat /proc/drbd
echo "Sleeping..."
sleep 5
cat /proc/drbd

# Set up LVM - PRIMARY NODE ONLY!
if [[ $nodetype == "p" ]]; then
  pvcreate /dev/drbd0
  vgcreate VG_PG /dev/drbd0
  lvcreate -L 450M -n LV_DATA VG_PG
fi

# Set up the filesystem
mkdir -p -m 0700 /db/pgdata

# Use xfs for now
apt-get install xfsprogs
# Install Postgres too, we need its user
apt-get install postgresql-9.1 postgresql-contrib-9.1

# Create/mount FS - PRIMARY NODE ONLY!
if [[ $nodetype == "p" ]]; then
  mkfs.xfs -d agcount=8 /dev/VG_PG/LV_DATA
  mount -t xfs -o noatime,nodiratime,attr2 /dev/VG_PG/LV_DATA /db/pgdata
  chown postgres:postgres /db/pgdata
  chmod 0700 /db/pgdata
fi

# Get PG working

# Kill the default config and create a new one for ourselves
service postgresql stop
pg_dropcluster 9.1 main
pg_createcluster -d /db/pgdata \
  -s /var/run/postgresql 9.1 hapg
  
# Delete the created data files - SECONDARY NODE ONLY!
if [[ $nodetype == "s" ]]; then
  rm -Rf /db/pgdata/*
fi

# Change the PG listen address
sed -i "s/listen_address = .*#/listen_address = '*'        #/g" \
  /etc/postgresql/9.1/hapg/postgresql.conf

# Disable PG autostart
update-rc.d postgresql disable

# Fix PG initscript
sed -i 's/set +e//g' /etc/init.d/postgresql

# Create a sample db - PRIMARY NODE ONLY!
if [[ $nodetype == "p" ]]; then
  service postgresql start
  export PATH=$PATH:/usr/lib/postgresql/9.1/bin
  sudo -u postgres "createdb pgbench"
  sudo -u postgres "pgbench -i -s 5 pgbench"
fi

# Set up Pacemaker
# Install pacemaker and corosync
apt-get install corosync pacemaker

# Modify corosync bindnetaddr
sed -i "s/bindnetaddr: .*/bindnetaddr: ${broadcastip}/g" \
  /etc/corosync/corosync.conf
  
# Start corosync on both nodes
sed -i 's/=no/=yes/' \
  /etc/default/corosync
service corosync start

# Wait for both to appear
echo "Waiting for both nodes to come online..."
while ! (crm_mon | grep Online.*${primaryname}.*${secondaryname}); do
  sleep 2
done

# Configure pacemaker
crm configure property stonith-enabled="false"
crm configure property no-quorum-policy="ignore"
crm configure property default-resource-stickiness="100"

# Set up Pacemaker resources - PRIMARY NODE ONLY!
if [[ $nodetype == "p" ]]; then
  crm configure primitive drbd_pg ocf:linbit:drbd \
    params drbd_resource="pg" \
    op monitor interval="15" \
    op start interval="0" timeout="240" \
    op stop interval="0" timeout="120"
    
  crm configure ms ms_drbd_pg drbd_pg \
    meta master-max="1" master-node-max="1" clone-max="2" \
      clone-node-max="1" notify="true"
      
  crm configure primitive pg_lvm ocf:heartbeat:LVM \
    params volgrpname="VG_PG" \
    op start interval="0" timeout="30" \
    op stop interval="0" timeout="30"
    
  crm configure primitive pg_fs ocf:heartbeat:Filesystem \
    params device="/dev/VG_PG/LV_DATA" directory="/db/pgdata" \
      options="noatime,nodiratime" fstype="xfs" \
    op start interval="0" timeout="60" \
    op stop interval="0" timeout="120"
    
  crm configure primitive pg_lsb lsb:postgresql \
    op monitor interval="30" timeout="60" \
    op start interval="0" timeout="60" \
    op stop interval="0" timeout="60"
    
  crm configure primitive pg_vip ocf:heartbeat:IPaddr2 \
    params ip="${virtualip}" iflabel="pgvip" \
    op monitor interval="5"
    
  crm configure group PGServer pg_lvm pg_fs pg_lsb pg_vip
  
  crm configure colocation col_pg_drbd inf: PGServer \
    ms_drbd_pg:Master
    
  crm configure order ord_pg inf: ms_drbd_pg:promote \
    PGServer:start
fi

echo "All done."
echo "Now test stuff."
