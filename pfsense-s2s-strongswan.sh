rg=pfsense-s2s-strongswan
location='centralindia'
vhdUri=https://wadvhds.blob.core.windows.net/vhds/pfsense.vhd
storageType=Premium_LRS
site1_vnet_name='site1'
site1_vnet_address='10.1.0.0/16'
site1_fw_subnet_name='fw'
site1_fw_subnet_address='10.1.0.0/24'
site1_vm_subnet_name='vm'
site1_vm_subnet_address='10.1.1.0/24'

site2_vnet_name='site2'
site2_vnet_address='10.2.0.0/16'
site2_fw_subnet_name='fw'
site2_fw_subnet_address='10.2.0.0/24'
site2_vm_subnet_name='vm'
site2_vm_subnet_address='10.2.1.0/24'

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

# pfsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $site1_vnet_name-fw...\e[0m"
az vm boot-diagnostics enable -g $rg -n $site1_vnet_name-fw -o none

# site2 vnet
echo -e "\e[1;36mCreating $site2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $site2_vnet_name -l $location --address-prefixes $site2_vnet_address --subnet-name $site2_vm_subnet_name --subnet-prefixes $site2_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $site2_fw_subnet_name --address-prefixes $site2_fw_subnet_address --vnet-name $site2_vnet_name -o none

# site2 gw vm
echo -e "\e[1;36mDeploying $site2_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $site2_vnet_name-gw -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $site2_vnet_name-gw -l $location --vnet-name $site2_vnet_name --subnet $site2_fw_subnet_name --ip-forwarding true --public-ip-address $site2_vnet_name-gw -o none
az vm create -g $rg -n $site2_vnet_name-gw -l $location --image Ubuntu2404 --nics $site2_vnet_name-gw --os-disk-name $site2_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# site2 gw details
site2_gw_pubip=$(az network public-ip show -g $rg -n $site2_vnet_name-gw --query ipAddress -o tsv | tr -d '\r') && echo $site2_vnet_name-gw public ip: $site2_gw_pubip
site2_gw_private_ip=$(az network nic show -g $rg -n $site2_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r')  && echo $site2_vnet_name-gw private ip: $site2_gw_private_ip

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
site1_config=~/site1-pfsense-config.xml
curl -o $site1_config https://raw.githubusercontent.com/wshamroukh/s2s-pfsense/refs/heads/main/site1-pfsense-config.xml
sed -i -e "s/20\.204\.179\.189/${site1_fw_public_ip}/g" -e "s/4\.213\.183\.129/${site2_gw_pubip}/g" $site1_config

# Copying config files to site1 pfsense
echo -e "\e[1;36mCopying configuration files to $site1_vnet_name-fw and installing opnsense firewall...\e[0m"
scp -o StrictHostKeyChecking=no $site1_config admin@$site1_fw_public_ip:/cf/conf/config.xml
echo -e "\e[1;36mRebooting $site1_vnet_name-fw after importing the config file...\e[0m"
ssh -o StrictHostKeyChecking=no admin@$site1_fw_public_ip "sudo reboot"

# clean up config file
rm $site1_config

#######################
# site2 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $site2_vnet_name Gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$site2_gw_pubip $site1_fw_public_ip : PSK $psk
EOF

ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn $site1_vnet_name-gw
         dpdaction=restart
         ike=aes256-sha256-modp2048
         esp=aes256-sha256
         keyexchange=ikev2
         ikelifetime=28800s
         keylife=3600s
         authby=secret
         # site2 private ip address
         left=$site2_gw_private_ip
         # site2 Public ip address
         leftid=$site2_gw_pubip
         # site2 Address Space2
         leftsubnet=$site2_vnet_address
         # Site1 VPN Gateway Public IP
         right=$site1_fw_public_ip
         # Site1 VPN Gateway Public IP
         rightid=$site1_fw_public_ip
         # Site1 Vnet Address Spaces and onther on-premises network address space (comma separated, if more that one i.e hub and spoke topology)
         rightsubnet=$site1_vnet_address
         auto=start
EOF

##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S VPN Config files to $site2_vnet_name-gw Gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $site2_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $site2_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pubip "sudo cp /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $site2_gw_pubip "sudo ipsec statusall"

echo -e "\e[1;36mChecking connectivity from $site1_vnet_name-fw to $site2_vnet_name network...\e[0m"
ssh -o StrictHostKeyChecking=no admin@$site1_fw_public_ip "ping -c 3 $site2_gw_private_ip && ping -c 3 $site2_vm_ip"

echo -e "\e[1;36mChecking connectivity from $site2_vnet_name-fwgw to $site1_vnet_name network...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $admin_username@$site2_gw_pubip "ping -c 3 $site1_fw_wan_private_ip && ping -c 3 $site1_fw_lan_private_ip && ping -c 3 $site1_vm_ip"


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