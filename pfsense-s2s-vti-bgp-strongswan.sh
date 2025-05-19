rg=pfsense-s2s-vti-bgp-strongswan
location='centralindia'
vhdUri=https://wadvhds.blob.core.windows.net/vhds/pfsense.vhd
storageType=Premium_LRS
site1_vnet_name='site1'
site1_vnet_address='10.1.0.0/16'
site1_fw_subnet_name='fw'
site1_fw_subnet_address='10.1.0.0/24'
site1_vm_subnet_name='vm'
site1_vm_subnet_address='10.1.1.0/24'
site1_fw_vti_ip=10.1.0.200
site1_fw_asn=65521

site2_vnet_name='site2'
site2_vnet_address='10.2.0.0/16'
site2_fw_subnet_name='fw'
site2_fw_subnet_address='10.2.0.0/24'
site2_vm_subnet_name='vm'
site2_vm_subnet_address='10.2.1.0/24'
site2_fw_vti_ip=10.2.0.200
site2_fw_asn=65522

vm_size=Standard_B2ats_v2
admin_username=$(whoami)
admin_password='Test#123#123'
myip=$(curl -s4 https://ifconfig.co/)
psk=secret12345

cloudinit_file=cloudinit.txt
cat <<EOF > $cloudinit_file
#cloud-config
runcmd:
  - curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee /usr/share/keyrings/frrouting.gpg > /dev/null
  - echo deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr \$(lsb_release -s -c) frr-stable | sudo tee -a /etc/apt/sources.list.d/frr.list
  - sudo apt update && sudo apt install -y frr frr-pythontools
  - sudo apt install -y strongswan inetutils-traceroute net-tools
  - sudo sed -i "/bgpd=no/ s//bgpd=yes/" /etc/frr/daemons
  - sudo service frr restart
  - touch /etc/strongswan.d/ipsec-vti.sh
  - chmod +x /etc/strongswan.d/ipsec-vti.sh
  - cp /etc/ipsec.conf /etc/ipsec.conf.bak
  - cp /etc/ipsec.secrets /etc/ipsec.secrets.bak
  - echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - echo "net.ipv4.conf.default.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - sudo sysctl -p
EOF

function first_ip(){
    subnet=$1
    IP=$(echo $subnet | cut -d/ -f 1)
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}

# create resource group
echo -e "\e[1;36mCreating $rg resource group...\e[0m"
az group create -l $location -n $rg -o none

# site1 vnet
echo -e "\e[1;36mCreating $site1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $site1_vnet_name -l $location --address-prefixes $site1_vnet_address --subnet-name $site1_vm_subnet_name --subnet-prefixes $site1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $site1_fw_subnet_name --address-prefixes $site1_fw_subnet_address --vnet-name $site1_vnet_name -o none

# create a managed disk from a vhd
echo -e "\e[1;36mCreating $site1_vnet_name-fw managed disk from a vhd...\e[0m"
az disk create --resource-group $rg --name $site1_vnet_name-fw --sku $storageType --location $location --size-gb 30 --source $vhdUri --os-type Linux -o none
#Get the resource Id of the managed disk
diskId=$(az disk show --name $site1_vnet_name-fw --resource-group $rg --query [id] -o tsv | tr -d '\r')

# Create pfsense VM by attaching existing managed disks as OS
echo -e "\e[1;36mCreating $site1_vnet_name-fw VM...\e[0m"
az network public-ip create -g $rg -n $site1_vnet_name-fw -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $site1_vnet_name-fw-wan --subnet $site1_fw_subnet_name --vnet-name $site1_vnet_name --ip-forwarding true --private-ip-address 10.1.0.250 --public-ip-address $site1_vnet_name-fw -o none
az network nic create -g $rg -n $site1_vnet_name-fw-lan --subnet $site1_vm_subnet_name --vnet-name $site1_vnet_name --ip-forwarding true --private-ip-address 10.1.1.250 -o none
az vm create --name $site1_vnet_name-fw --resource-group $rg --nics $site1_vnet_name-fw-wan $site1_vnet_name-fw-lan --size Standard_B2als_v2 --attach-os-disk $diskId --os-type linux -o none
site1_fw_public_ip=$(az network public-ip show -g $rg -n $site1_vnet_name-fw --query 'ipAddress' -o tsv | tr -d '\r') && echo $site1_vnet_name-fw public ip: $site1_fw_public_ip
site1_fw_wan_private_ip=$(az network nic show -g $rg -n $site1_vnet_name-fw-wan --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site1_vnet_name-fw wan private IP: $site1_fw_wan_private_ip
site1_fw_lan_private_ip=$(az network nic show -g $rg -n $site1_vnet_name-fw-lan --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site1_vnet_name-fw lan private IP: $site1_fw_lan_private_ip
site1_fw_nic_default_gw=$(first_ip $site1_fw_subnet_address) && echo $site1_vnet_name-fw default gateway ip: $site1_fw_nic_default_gw

# pfsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $site1_vnet_name-fw...\e[0m"
az vm boot-diagnostics enable -g $rg -n $site1_vnet_name-fw -o none

# site1 gw nsg
echo -e "\e[1;36mCreating $site1_vnet_name-fw NSG...\e[0m"
az network nsg create -g $rg -n $site1_vnet_name-fw -l $location -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $site1_vnet_name-fw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPin --nsg-name $site1_vnet_name-fw --priority 1010 --access Allow --description AllowHTTP --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 80 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPSin --nsg-name $site1_vnet_name-fw --priority 1020 --access Allow --description AllowHTTPS --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 443 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $site1_vnet_name-fw --priority 1030 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $site1_vnet_name-fw --priority 1040 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $site1_vnet_name-fw --priority 1050 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $site1_vnet_name-fw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $site1_vnet_name-fw --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $site1_fw_subnet_name --vnet-name $site1_vnet_name --nsg $site1_vnet_name-fw -o none

# site2 vnet
echo -e "\e[1;36mCreating $site2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $site2_vnet_name -l $location --address-prefixes $site2_vnet_address --subnet-name $site2_vm_subnet_name --subnet-prefixes $site2_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $site2_fw_subnet_name --address-prefixes $site2_fw_subnet_address --vnet-name $site2_vnet_name -o none

# site2 gw vm
echo -e "\e[1;36mDeploying $site2_vnet_name-fw VM...\e[0m"
az network public-ip create -g $rg -n $site2_vnet_name-fw -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $site2_vnet_name-fw -l $location --vnet-name $site2_vnet_name --subnet $site2_fw_subnet_name --ip-forwarding true --public-ip-address $site2_vnet_name-fw -o none
az vm create -g $rg -n $site2_vnet_name-fw -l $location --image Ubuntu2404 --nics $site2_vnet_name-fw --os-disk-name $site2_vnet_name-fw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# site2 gw details
site2_fw_pubip=$(az network public-ip show -g $rg -n $site2_vnet_name-fw --query ipAddress -o tsv | tr -d '\r') && echo $site2_vnet_name-fw public ip: $site2_fw_pubip
site2_fw_private_ip=$(az network nic show -g $rg -n $site2_vnet_name-fw --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r')  && echo $site2_vnet_name-fw private ip: $site2_fw_private_ip
site2_fw_nic_default_gw=$(first_ip $site2_fw_subnet_address) && echo $site2_vnet_name-fw default gateway ip: $site2_fw_nic_default_gw
# site2 gw nsg
echo -e "\e[1;36mCreating $site2_vnet_name-fw NSG...\e[0m"
az network nsg create -g $rg -n $site2_vnet_name-fw -l $location -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $site2_vnet_name-fw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPin --nsg-name $site2_vnet_name-fw --priority 1010 --access Allow --description AllowHTTP --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 80 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPSin --nsg-name $site2_vnet_name-fw --priority 1020 --access Allow --description AllowHTTPS --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 443 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $site2_vnet_name-fw --priority 1030 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $site2_vnet_name-fw --priority 1040 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $site2_vnet_name-fw --priority 1050 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $site2_vnet_name-fw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $site2_vnet_name-fw --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $site2_fw_subnet_name --vnet-name $site2_vnet_name --nsg $site2_vnet_name-fw -o none

# site1 vm
echo -e "\e[1;36mCreating $site1_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$site1_vnet_name" -l $location --vnet-name $site1_vnet_name --subnet $site1_vm_subnet_name -o none
az vm create -g $rg -n $site1_vnet_name -l $location --image Ubuntu2404 --nics "$site1_vnet_name" --os-disk-name "$site1_vnet_name" --size $vm_size --admin-username $admin_username --admin-password $admin_password --no-wait -o none
site1_vm_ip=$(az network nic show -g $rg -n $site1_vnet_name --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site1_vnet_name vm private ip: $site1_vm_ip

# site2 vm
echo -e "\e[1;36mCreating $site2_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$site2_vnet_name" -l $location --vnet-name $site2_vnet_name --subnet $site2_vm_subnet_name -o none
az vm create -g $rg -n $site2_vnet_name -l $location --image Ubuntu2404 --nics "$site2_vnet_name" --os-disk-name "$site2_vnet_name" --size $vm_size --admin-username $admin_username --admin-password $admin_password --no-wait -o none
site2_vm_ip=$(az network nic show -g $rg -n $site2_vnet_name --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site2_vnet_name vm private ip: $site2_vm_ip

# site1 route table
echo -e "\e[1;36mCreating $site1_vnet_name route table....\e[0m"
az network route-table create -g $rg -n $site1_vnet_name -l $location -o none
az network route-table route create -g $rg -n to-site2 --address-prefix $site2_vnet_address --next-hop-type virtualappliance --route-table-name $site1_vnet_name --next-hop-ip-address $site1_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n $site1_vm_subnet_name --vnet-name $site1_vnet_name --route-table $site1_vnet_name -o none

# site2 route table
echo -e "\e[1;36mCreating $site2_vnet_name route table....\e[0m"
az network route-table create -g $rg -n $site2_vnet_name -l $location -o none
az network route-table route create -g $rg -n to-site2 --address-prefix $site1_vnet_address --next-hop-type virtualappliance --route-table-name $site2_vnet_name --next-hop-ip-address $site2_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n $site2_vm_subnet_name --vnet-name $site2_vnet_name --route-table $site2_vnet_name -o none

# Download config files
site1_config=~/pfsense-vti-config.xml
curl -o $site1_config https://raw.githubusercontent.com/wshamroukh/s2s-pfsense/refs/heads/main/pfsense-vti-config.xml
sed -i -e "s/20\.244\.125\.121/${site1_fw_public_ip}/g" -e "s/20\.204\.160\.195/${site2_fw_pubip}/g" $site1_config
# Copying config files to site1 pfsense
echo -e "\e[1;36mCopying configuration files to $site1_vnet_name-fw and rebooting..\e[0m"
scp -o StrictHostKeyChecking=no $site1_config admin@$site1_fw_public_ip:/cf/conf/config.xml
echo -e "\e[1;36mRebooting $site1_vnet_name-fw after importing the config file...\e[0m"
ssh -o StrictHostKeyChecking=no admin@$site1_fw_public_ip "sudo reboot"

# clean up config file
rm $site1_config

#######################
# site2 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $site2_vnet_name-fw gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$site2_fw_pubip $site1_fw_public_ip : PSK $psk
EOF

# ipsec.conf
ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn %default
         # Authentication Method : Pre-Shared Key
         leftauth=psk
         rightauth=psk
         ike=aes256-sha256-modp2048
         ikelifetime=28800s
         # Phase 1 Negotiation Mode : main
         aggressive=no
         esp=aes256-sha256
         lifetime=3600s
         keylife=3600s
         type=tunnel
         dpddelay=10s
         dpdtimeout=30s
         keyexchange=ikev2
         rekey=yes
         reauth=no
         dpdaction=restart
         closeaction=restart
         leftsubnet=0.0.0.0/0,::/0
         rightsubnet=0.0.0.0/0,::/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         installpolicy=yes
         compress=no
         mobike=no
conn $site1_vnet_name-fw0
         # OnPrem Gateway Private IP Address :
         left=$site2_fw_private_ip
         # OnPrem Gateway Public IP Address :
         leftid=$site2_fw_pubip
         # Azure VPN Gateway Public IP address :
         right=$site1_fw_public_ip
         rightid=$site1_fw_public_ip
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
EOF


# ipsec-vti.sh
ipsec_vti_file=~/ipsec-vti.sh
tee $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash

#
# /etc/strongswan.d/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)
PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })
case "$PLUTO_CONNECTION" in
  $site1_vnet_name-fw0)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$site2_fw_vti_ip/32
    VTI_REMOTEADDR=$site1_fw_vti_ip/32
    ;;
esac
echo "`date` ${PLUTO_VERB} $VTI_INTERFACE" >> /tmp/vtitrace.log
case "${PLUTO_VERB}" in
    up-client)
        $IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
        $IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
        $IP link set ${VTI_INTERFACE} up mtu 1350
        $IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        $IP route flush table 220
        /etc/init.d/frr force-reload bgpd
        ;;
    down-client)
        $IP link del ${VTI_INTERFACE}
        $IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
EOT

sed -i "/\$site2_fw_vti_ip/ s//$site2_fw_vti_ip/" $ipsec_vti_file
sed -i "/\$site2_fw_vti1/ s//$site2_fw_vti1/" $ipsec_vti_file
sed -i "/\$site1_fw_vti_ip/ s//$site1_fw_vti_ip/" $ipsec_vti_file
sed -i "/\$site1_fw_bgp_ip1/ s//$site1_fw_bgp_ip1/" $ipsec_vti_file
sed -i "/\$site1_vnet_name-fw0/ s//$site1_vnet_name-fw0/" $ipsec_vti_file
sed -i "/\$site1_vnet_name-fw1/ s//$site1_vnet_name-fw1/" $ipsec_vti_file

# frr.conf
frr_conf_file=~/frr.conf
cat <<EOF > $frr_conf_file
frr version 10.3
frr defaults traditional
hostname $site2_vnet_name-fw
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $site2_vnet_address $site2_fw_nic_default_gw
ip route $site1_fw_vti_ip/32 $site2_fw_nic_default_gw
!
router bgp $site2_fw_asn
 bgp router-id $site2_fw_private_ip
 no bgp ebgp-requires-policy
 neighbor $site1_fw_vti_ip remote-as $site1_fw_asn
 neighbor $site1_fw_vti_ip description $site1_vnet_name-fw
 neighbor $site1_fw_vti_ip ebgp-multihop 2
 !
 address-family ipv4 unicast
  network $site2_vnet_address
  neighbor $site1_fw_vti_ip soft-reconfiguration inbound
 exit-address-family
exit
!
EOF

##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S/BGP VPN Config files to $site2_vnet_name-fw gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $site2_fw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $site2_fw_pubip:/home/$admin_username/.ssh/
# This is needed for clients to connect to internet through onprem gw
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo mv /home/$admin_username/frr.conf /etc/frr/frr.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo chmod +x /etc/strongswan.d/ipsec-vti.sh"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo service frr restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo ipsec statusall"

# clean up config files
rm $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file

# wait for pfsense to come up
sleep 120
# Apply BGP config to site1 pfsense
echo -e "\e[1;36mCopying and applying BGP on $site1_vnet_name-fw gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no pfsense_frr.conf admin@$site1_fw_public_ip:/var/etc/frr/frr.conf
ssh -o StrictHostKeyChecking=no admin@$site1_fw_public_ip "service frr restart"

# Diagnosis

echo -e "\e[1;36mChecking connectivity from $site1_vnet_name-fw to $site2_vnet_name network...\e[0m"
ssh -o StrictHostKeyChecking=no admin@$site1_fw_public_ip "ping -c 3 $site2_fw_vti_ip &&ping -c 3 $site2_fw_private_ip && ping -c 3 $site2_vm_ip"

echo -e "\e[1;36mChecking connectivity from $site2_vnet_name-fwgw to $site1_vnet_name network...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $admin_username@$site2_fw_pubip "ping -c 3 $site1_fw_vti_ip && ping -c 3 $site1_fw_wan_private_ip && ping -c 3 $site1_fw_lan_private_ip && ping -c 3 $site1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show ip bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show ip route bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show bgp all'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show ip bgp neighbors $site1_fw_vti_ip received-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show ip bgp neighbors $site1_fw_vti_ip advertised-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_fw_pubip "sudo vtysh -c 'show bgp neighbors $site1_fw_vti_ip'"

# clean up config files
rm $psk_file $ipsec_file $cloudinit_file

# Follow this documentation to configure pfsense ipsec s2s vpn between the two sites: https://docs.netgate.com/pfsense/en/latest/recipes/ipsec-s2s-psk.html but take the following into account:
# 1. In phase 1, set 'My identifier'/'Peer identifier' to IP address and put the public ip address of each pfsense firewall
# 2. in phase 2, set the 'local network'/'remote network' to network and put the $site1_vnet_address and $site2_vnet_address
# 3. In the IPSec firewall rule, set the 'destination' to 'network' and out source as other pfsense vnet address space, while destination as the current pfsense vnet address space
# credentials for pfsense web interface:
# username: admin
# password: pfsense

# az group delete -n $rg -y --no-wait