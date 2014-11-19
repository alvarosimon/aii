# ${license-info}
# ${developer-info}
# ${author-info}

package AII::opennebula;

use strict;
use warnings;
use version;
use CAF::Process;
use Set::Scalar;
use Template;

use Config::Tiny;
use Net::OpenNebula 0.2.2;
use Data::Dumper;

use constant TEMPLATEPATH => "/usr/share/templates/quattor";
use constant AII_OPENNEBULA_CONFIG => "/etc/aii/opennebula.conf";
use constant HOSTNAME => "/system/network/hostname";
use constant DOMAINNAME => "/system/network/domainname";
use constant MAXITER => 20;
use constant TIMEOUT => 30;
use constant MINIMAL_ONE_VERSION => version->new("4.8.0");

# a config file in .ini style with minmal 
#   [rpc]
#   password=secret
sub make_one 
{
    my $self = shift;
    my $filename = shift || AII_OPENNEBULA_CONFIG;

    if (! -f $filename) {
        $main::this_app->error("No configfile $filename.");
        return;
    }

    my $config = Config::Tiny->new;

    $config = Config::Tiny->read($filename);
    my $port = $config->{rpc}->{port} || 2633;
    my $host = $config->{rpc}->{host} || "localhost";
    my $user = $config->{rpc}->{user} || "oneadmin";
    my $password = $config->{rpc}->{password};

    if (! $password ) {
        $main::this_app->error("No password set in configfile $filename.");
        return;
    }
    
    my $one = Net::OpenNebula->new(
        url      => "http://$host:$port/RPC2",
        user     => $user,
        password => $password,
        log => $main::this_app,
        fail_on_rpc_fail => 0,
    );

    if (!$one) {
        $main::this_app->error("No ONE instance.");
        return;
    }

    return $one;
}

sub process_template 
{
    my ($self, $config, $tt_name) = @_;
    my $res;
    my $tt_rel = "metaconfig/opennebula/$tt_name.tt";
    my $tree = $config->getElement('/')->getTree();
    my $tpl = Template->new(INCLUDE_PATH => TEMPLATEPATH);
    if (! $tpl->process($tt_rel, $tree, \$res)) {
        $main::this_app->error("TT processing of $tt_rel failed: ", $tpl->error());
        return;
    }
    return $res;
}

# Return fqdn of the node
sub get_fqdn
{
    my ($self,$config) = @_;
    my $hostname = $config->getElement (HOSTNAME)->getValue;
    my $domainname = $config->getElement (DOMAINNAME)->getValue;
    return "${hostname}.${domainname}";
}

# It gets the image template from tt file
# and gathers image names format: <fqdn>_<vdx> 
# and datastore names to store the new images 
sub get_images
{
    my ($self, $config) = @_;
    my $all_images = $self->process_template($config, "imagetemplate");
    my %res;

    my @tmp = split(qr{^DATASTORE\s+=\s+(?:"|')(\S+)(?:"|')\s*$}m, $all_images);

    while (my ($image,$datastore) = splice(@tmp, 0, 2)) {
        my $imagename = $1 if ($image =~ m/^NAME\s+=\s+(?:"|')(.*?)(?:"|')\s*$/m);
        if ($datastore && $imagename) {
            $main::this_app->verbose("Detected imagename $imagename",
                                    " with datastore $datastore");
            $res{$imagename}{image} = $image;
            $res{$imagename}{datastore} = $datastore;
            $main::this_app->debug(3, "This is image template $imagename: $image");
        } else {
            # Shouldn't happen; fields are in TT
            $main::this_app->error("No datastore and/or imagename for image data $image.");
        };
    }
    return %res;
}

# It gets the network ARs (address range) from tt file
# and gathers vnet names and IPs/MAC addresses
sub get_vnetars
{
    my ($self, $config) = @_;
    my $all_ars = $self->process_template($config, "aii_network_ar");
    my %res;

    my @tmp = split(qr{^NETWORK\s+=\s+(?:"|')(\S+)(?:"|')\s*$}m, $all_ars);

    while (my ($ar,$network) = splice(@tmp, 0 ,2)) {

        if ($network && $ar) {
            $main::this_app->verbose("Detected network AR: $ar",
                                     " within network $network");
            $res{$network}{ar} = $ar;
            $res{$network}{network} = $network;
            $main::this_app->debug(3, "This is the network AR template for $network: $ar");
        } else {
            # No ars found for this VM
            $main::this_app->error("No network ARs and/or network info $ar.");
        };
    }
    return %res;
}

sub get_vmtemplate
{
    my ($self, $config) = @_;
    my ($vmtemplatename, $quattor);

    my $vm_template = $self->process_template($config, "vmtemplate");
    $vmtemplatename = $1 if ($vm_template =~ m/^NAME\s+=\s+(?:"|')(.*?)(?:"|')\s*$/m);
    $quattor = $1 if ($vm_template =~ m/^QUATTOR\s+=\s+(.*?)\s*$/m);

    if ($vmtemplatename && $quattor) {
        $main::this_app->verbose("The VM template name: $vmtemplatename was generated by QUATTOR.");
    } else {
        # VM template name is mandatory
        $main::this_app->error("No VM template name or QUATTOR flag found.");
        return undef;
    };

    $main::this_app->debug(3, "This is vmtemplate $vmtemplatename: $vm_template.");
    return $vm_template
}

sub new
{
    my $class = shift;
    return bless {}, $class;
}

sub remove_and_create_vm_images
{
    my ($self, $one, $forcecreateimage, $imagesref, $remove) = @_;
    my (@rimages, @nimages, @qimages, $newimage, $count);
    foreach my $imagename (sort keys %{$imagesref}) {
        my $imagedata = $imagesref->{$imagename};
        $main::this_app->info ("Checking ONE image: $imagename");
        push(@qimages, $imagename);
        my @existimage = $one->get_images(qr{^$imagename$});
        foreach my $t (@existimage) {
            if (($t->{extended_data}->{TEMPLATE}->[0]->{QUATTOR}->[0]) && ($forcecreateimage)) {
                # It's safe, we can remove the image
                $main::this_app->info("Removing VM image: $imagename");
                my $id = $t->delete();
                eval {
                    local $SIG{ALRM} = sub { die "alarm\n" };
                    alarm TIMEOUT;
                    do {
                        sleep(2);
                    } while($self->is_one_resource_available($one, "image", $imagename));
                    alarm 0;
                };
                if ($@) {
                    die unless $@ eq "alarm\n";
                    $main::this_app->error("VM image deletion: $imagename. TIMEOUT"); 
                }

                if ($id) {
                    push(@rimages, $imagename);
                } else {
                    $main::this_app->error("VM image: $imagename was not removed");
                }
            } else {
                $main::this_app->info("No QUATTOR flag found for VM image: $imagename");
            }
        }
    	# And create the new image with the image data
        if (!$remove) {
            if ($self->is_one_resource_available($one, "image", $imagename)) {
                $main::this_app->error("Image: $imagename is already used and AII hook: image is not set. ",
                                        "Please remove this image first.");
            } else {
                $newimage = $one->create_image($imagedata->{image}, $imagedata->{datastore});
            }
            if ($newimage) {
                $main::this_app->info("Created new VM image ID: ", $newimage->id);
                push(@nimages, $imagename);
            } else {
                $main::this_app->error("VM image: $imagename is not available");
            }
    	}
    }

    if ($remove) {
        my $diff = $self->check_vm_images_list(\@rimages, \@qimages);
        if ($diff) { 
            $main::this_app->error("Removing these VM images: ", join(',', @qimages));
        }
    } else {
        my $diff = $self->check_vm_images_list(\@nimages, \@qimages);
        if ($diff) { 
            $main::this_app->error("Creating these VM images: ", join(',', @qimages));
        }
    }
}

# This function checks the difference between two image lists
# to detect if the images were correctly created/removed
sub check_vm_images_list
{
    my ($self, $myimages, $qimages) = @_;

    my $a = Set::Scalar->new(@{$qimages});
    my $b = Set::Scalar->new(@{$myimages});
    return $a->symmetric_difference($b);
}

# Since ONE 4.8 we use network address ranges (ARs)
# instead of leases. This function removes/creates ARs
sub remove_and_create_vn_ars
{
    my ($self, $one, $arsref, $remove) = @_;
    my $arid;
    foreach my $vnet (sort keys %{$arsref}) {
        my $ardata = $arsref->{$vnet};
        $main::this_app->info ("Testing ONE vnet network AR: $vnet");

        my %ar_opts = ('template' => $ardata->{ar});
        my @exisvnet = $one->get_vnets(qr{^$vnet$});
        foreach my $t (@exisvnet) {
            my $arinfo = $t->get_ar(%ar_opts);
            if ($remove) {
                # Detect Quattor and id first
                $arid = $self->detect_vn_ar_quattor($arinfo) if $arinfo;
                if (defined($arid)) {
                    $main::this_app->debug(1, "AR template to remove from $vnet: ", $ardata->{ar});
                    my $rmid = $t->rmar($arid);
                    if (defined($rmid)) {
                        $main::this_app->info("Removed from vnet: $vnet AR id: $arid");
                    } else {
                        $main::this_app->error("Unable to remove AR id: $arid from vnet: $vnet");
                    }
                } elsif ($arinfo) {
                    $main::this_app->error("Quattor flag not found within AR. ", 
                                        "ONE AII is not allowed to remove this AR.");
                } else {
                    $main::this_app->debug(1, "Unable to remove AR. ",
                                        "AR template is not available from vnet: $vnet: ", $ardata->{ar});
                }
            } elsif (!$remove and $arinfo) {
                # Update the AR info
                $main::this_app->debug(1, "AR template to update from $vnet: ", $ardata->{ar});
                $arid = $t->updatear($ardata->{ar});
                if (defined($arid)) {
                    $main::this_app->info("Updated $vnet AR id: ", $arid);
                } else {
                    $main::this_app->error("Unable to update AR from vnet: $vnet");
                }
            } else { 
                # Create a new network AR
                $main::this_app->debug(1, "New AR template in $vnet: ", $ardata->{ar});
                $arid = $t->addar($ardata->{ar});
                if (defined($arid)) {
                    $main::this_app->info("Created new $vnet AR id: ", $arid);
                } else {
                    $main::this_app->error("Unable to create new AR within vnet: $vnet");
                }
            }
       }
    }
}

# Detects Quattor flag within AR template
sub detect_vn_ar_quattor
{
    my ($self, $ar)  =@_;
    my $arid = $ar->{AR_ID}->[0];

    if ($ar->{QUATTOR}->[0]) {
            $main::this_app->info("QUATTOR flag found within AR, id: $arid");
            return $arid;
    } else {
            $main::this_app->info("QUATTOR flag not found within AR, id: $arid");
            return;
    }
}

sub stop_and_remove_one_vms
{
    my ($self, $one, $fqdn) = @_;
    # Quattor only stops and removes fqdn names
    # running VM names such: fqdn-<ID> are not removed
    my @runningvms = $one->get_vms(qr{^$fqdn$});

    # check if the running $fqdn has QUATTOR = 1
    # if not don't touch it!!
    foreach my $t (@runningvms) {
        if ($t->{extended_data}->{USER_TEMPLATE}->[0]->{QUATTOR}->[0]) {
            $main::this_app->info("Running VM will be removed: ",$t->name);
            $t->delete();
        } else {
            $main::this_app->info("No QUATTOR flag found for Running VM: ",$t->name);
        }
    }
}

# Creates and removes VM templates
# $createvmtemplate hook forces to remove/create
sub remove_and_create_vm_template
{
    my ($self, $one, $fqdn, $createvmtemplate, $vmtemplate, $remove) = @_;
    
    # Check if the vm template already exists
    my @existtmpls = $one->get_templates(qr{^$fqdn$});

    foreach my $t (@existtmpls) {
        if ($t->{extended_data}->{TEMPLATE}->[0]->{QUATTOR}->[0]) {
            if ($createvmtemplate) {
                # force to remove and create the template again
                $main::this_app->info("QUATTOR VM template, going to delete: ",$t->name);
                $t->delete();
            } else {
                # Update the current template
                $main::this_app->info("QUATTOR VM template, going to update: ",$t->name);
                $self->debug(1, "New $fqdn template : $vmtemplate");
                my $update = $t->update($vmtemplate, 0);
                return $update;
            }
        } else {
            $main::this_app->info("No QUATTOR flag found for VM template: ",$t->name);
        }
    }
    
    if ($createvmtemplate && !$remove) {
        my $templ = $one->create_template($vmtemplate);
        $main::this_app->debug(1, "New ONE VM template name: ",$templ->name);
        return $templ;
    }
}

# Check RPC endpoint and ONE version
# returns false if ONE version is not supported by AII
sub is_supported_one_version
{
    my ($self, $one) = @_;

    my $oneversion = $one->version();

    if ($oneversion) {
        $main::this_app->info("Detected OpenNebula version: $oneversion");
    } else {
        $main::this_app->error("OpenNebula RPC endpoint is not reachable.");
        return;
    }

    my $res= $oneversion >= MINIMAL_ONE_VERSION;
    if ($res) {
        $main::this_app->verbose("Version $oneversion is ok.");
    } else {
        $main::this_app->error("OpenNebula AII requires ONE v".MINIMAL_ONE_VERSION." or higher (found $oneversion).");
    }
    return $res;
}

# Detects if the resource is already there
# return undef: resource not used yet
# return 1: resource already used
sub is_one_resource_available
{
    my ($self, $one, $type, $name) = @_;
    my $gmethod = "get_${type}s";
    my @existres = $one->$gmethod(qr{^$name$});
    if (@existres) {
        $main::this_app->info("Name: $name is already used by a $type resource.");
        return 1;
    }
    return;
}


# Based on Quattor template this function:
# creates new VM templates
# creates new VM image for each $harddisks
# creates new vnet ars if required
# instantiates the new VM
sub install
{
    my ($self, $config, $path) = @_;

    my $tree = $config->getElement($path)->getTree();

    my $forcecreateimage = $tree->{image};
    $main::this_app->info("Forcecreate image flag is set to: $forcecreateimage");
    my $instantiatevm = $tree->{vm};
    $main::this_app->info("Instantiate VM flag is set to: $instantiatevm");
    my $createvmtemplate = $tree->{template};
    $main::this_app->info("Create VM template flag is set to: $createvmtemplate");
    my $onhold = $tree->{onhold};
    $main::this_app->info("Start VM onhold flag is set to: $onhold");
        
    my $fqdn = $self->get_fqdn($config);
    my %opts;
    
    # Set one endpoint RPC connector
    my $one = make_one();
    if (!$one) {
        error("No ONE instance returned");
        return 0;
    }

    # Check RPC endpoint and OpenNebula version
    return 0 if !$self->is_supported_one_version($one);

    $self->stop_and_remove_one_vms($one, $fqdn);

    my %images = $self->get_images($config);
    $self->remove_and_create_vm_images($one, $forcecreateimage, \%images);

    my %ars = $self->get_vnetars($config);
    $self->remove_and_create_vn_ars($one, \%ars);

    my $vmtemplatetxt = $self->get_vmtemplate($config);
    my $vmtemplate = $self->remove_and_create_vm_template($one, $fqdn, $createvmtemplate, $vmtemplatetxt);

    if ($instantiatevm) {
    	$main::this_app->debug(1, "Instantiate vm with name $fqdn with template ", $vmtemplate->name);
    	
        # Check that image is in READY state.
        my @myimages = $one->get_images(qr{^${fqdn}\_vd[a-z]$});
        $opts{max_iter} = MAXITER;
        foreach my $t (@myimages) {
            # If something wrong happens set a timeout
            my $imagestate = $t->wait_for_state("READY", %opts);

            if ($imagestate) {
                $main::this_app->info("VM Image status: READY ,OK");
            } else {
                $main::this_app->error("TIMEOUT! Image status is not ready yet...");
            };
        }
        my $vmid = $vmtemplate->instantiate(name => $fqdn, onhold => $onhold);
        $main::this_app->info("VM ${fqdn} was created successfully with ID: ${vmid}");
    }
}

# Performs Quattor post_reboot
# ACPID service is mandatory for ONE VMs 
sub post_reboot
{
    my ($self, $config, $path) = @_;
    my $tree = $config->getElement($path)->getTree();

    print <<EOF;
yum -c /tmp/aii/yum/yum.conf -y install acpid
service acpid start
EOF
}

# Performs VM remove wich depending on the booleans
# Stops running VM
# Removes VM template
# Removes VM image for each $harddisks
# Removes vnet ars
sub remove
{
    my ($self, $config, $path) = @_;
    my $tree = $config->getElement($path)->getTree();
    my $rmimage = $tree->{image};
    $main::this_app->info("Remove image flag is set to: $rmimage");
    my $rmvmtemplate = $tree->{template};
    $main::this_app->info("Remove VM template flag is set to: $rmvmtemplate");
    my $fqdn = $self->get_fqdn($config);

    # Set one endpoint RPC connector
    my $one = make_one();
    if (!$one) {
        $main::this_app->error("No ONE instance returned");
        return 0;
    }

    # Check RPC endpoint and OpenNebula version
    return 0 if !$self->is_supported_one_version($one);

    $self->stop_and_remove_one_vms($one,$fqdn);

    my %images = $self->get_images($config);
    if (%images) {
        $self->remove_and_create_vm_images($one, 1, \%images, $rmimage);
    }

    my %ars = $self->get_vnetars($config);
    if (%ars) {
        $self->remove_and_create_vn_ars($one, \%ars, 1);
    }

    my $vmtemplatetxt = $self->get_vmtemplate($config);
    if ($vmtemplatetxt) {
        $self->remove_and_create_vm_template($one, $fqdn, 1, $vmtemplatetxt, $rmvmtemplate);
    }
}

1;
