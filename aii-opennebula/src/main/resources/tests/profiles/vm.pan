unique template vm;

prefix "/hardware";
"bios" = dict(
    "releasedate", "01/01/2007",
    "version", "0.5.1",
);
"cards" = dict(
    "bmc", list(dict("console", "ttyS0,115200")),
    "nic", dict(
        "eth0", dict("boot", "true", "hwaddr", "AA:00:00:80:01:00", "pxe", "true"),
        "eth1", dict("boot", "false", "hwaddr", "AA:00:00:80:01:01", "pxe", "true"),
    ),
);

"cpu" = list(
    dict(
        "arch", "x86_64",
        "cores", 2,
        "manufacturer", "Intel",
        "model", "Intel(R) Xeon(R) E5520 2.27GHz",
        "speed", 2260,
        "vendor", "Intel",
    ),
    dict(
        "arch", "x86_64",
        "cores", 2,
        "manufacturer", "Intel",
        "model", "Intel(R) Xeon(R) E5520 2.27GHz",
        "speed", 2260,
        "vendor", "Intel",
    )
);
"harddisks" = dict(
    "vda", dict(
        "capacity", 20480,
        "interface", "sas",
        "model", "Generic SAS disk",
        "part_prefix", ""
    ),
    "vdb", dict(
        "capacity", 10480,
        "interface", "sas",
        "model", "Generic SAS disk",
        "part_prefix", ""
    ),
);
"location" = "cubone hyp";
"model" = "KVM Virtual Machine";
"ram" = list (
    dict ("size", 2048,),
    dict ("size", 2048,),
);
"serialnumber" = "kvm/QUATTOR_IMAGE001";

prefix "/system/network";
"default_gateway" = "10.141.10.250";
"domainname" = "cubone.os";
"hostname" = "node630";
"interfaces" = dict(
    "br100", dict(
        "broadcast", "10.141.10.255",
        "delay", 0,
        "ip", "10.141.8.30",
        "linkdelay", 5,
        "netmask", "255.255.0.0",
        "stp", true,
        "type", "Bridge"
    ),
    "br101", dict(
        "broadcast", "172.24.255.255",
        "delay", 0,
        "ip", "172.24.8.30",
        "linkdelay", 5,
        "netmask", "255.255.0.0",
        "stp", true,
        "type", "Bridge"
    ),
    "eth0", dict(
        "bridge", "br100",
        "driver", "bnx2",
        "device", "eth0"
    ),
    "eth1", dict(
        "broadcast", "172.24.255.255",
        "device", "eth1",
        "ip", "172.24.8.30",
        "netmask", "255.255.0.0",
        "driver", "bnx2"
    ),
);

include 'quattor/aii/opennebula/schema';

bind "/system/opennebula" = opennebula_vmtemplate;

prefix "/system/opennebula";
"vnet" = dict(
    "eth0", "br100",
    "eth1", "br101");

"datastore" = dict(
    "vda", "ceph",
    "vdb", "default");
