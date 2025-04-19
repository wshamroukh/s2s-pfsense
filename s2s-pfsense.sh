rg=s2s-pfsense
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

# create resource group
echo -e "\e[1;36mCreating $rg resource group...\e[0m"
az group create -l $location -n $rg -o none

# site1 vnet
echo -e "\e[1;36mCreating $site1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $site1_vnet_name -l $location --address-prefixes $site1_vnet_address --subnet-name $site1_vm_subnet_name --subnet-prefixes $site1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $site1_fw_subnet_name --address-prefixes $site1_fw_subnet_address --vnet-name $site1_vnet_name -o none

# create a managed disk from a vhd
echo -e "\e[1;36mCreating $site1_vnet_name-fw managed disk from a vhd...\e[0m"
az disk create --resource-group $rg --name $site1_vnet_name-fw --sku $storageType --location $location --size-gb 30 --source $vhdUri --os-type Linux
#Get the resource Id of the managed disk
diskId=$(az disk show --name $site1_vnet_name-fw --resource-group $rg --query [id] -o tsv | tr -d '\r')

# Create pfsense VM by attaching existing managed disks as OS
echo -e "\e[1;36mCreating $site1_vnet_name-fw VM...\e[0m"
az network public-ip create -g $rg -n $site1_vnet_name-fw -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $site1_vnet_name-fw-wan --subnet $site1_fw_subnet_name --vnet-name $site1_vnet_name --ip-forwarding true --private-ip-address 10.1.0.250 --public-ip-address $site1_vnet_name-fw -o none
az network nic create -g $rg -n $site1_vnet_name-fw-lan --subnet $site1_vm_subnet_name --vnet-name $site1_vnet_name --ip-forwarding true --private-ip-address 10.1.1.250 -o none
az vm create --name $site1_vnet_name-fw --resource-group $rg --nics $site1_vnet_name-fw-wan $site1_vnet_name-fw-lan --size Standard_B2als_v2 --attach-os-disk $diskId --os-type linux
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

# create a managed disk from a vhd
echo -e "\e[1;36mCreating $site2_vnet_name-fw managed disk from a vhd...\e[0m"
az disk create --resource-group $rg --name $site2_vnet_name-fw --sku $storageType --location $location --size-gb 30 --source $vhdUri --os-type Linux
#Get the resource Id of the managed disk
diskId=$(az disk show --name $site2_vnet_name-fw --resource-group $rg --query [id] -o tsv | tr -d '\r')

# Create pfsense VM by attaching existing managed disks as OS
echo -e "\e[1;36mCreating $site2_vnet_name-fw VM...\e[0m"
az network public-ip create -g $rg -n $site2_vnet_name-fw -l $location --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $site2_vnet_name-fw-wan --subnet $site2_fw_subnet_name --vnet-name $site2_vnet_name --ip-forwarding true --private-ip-address 10.2.0.250 --public-ip-address $site2_vnet_name-fw -o none
az network nic create -g $rg -n $site2_vnet_name-fw-lan --subnet $site2_vm_subnet_name --vnet-name $site2_vnet_name --ip-forwarding true --private-ip-address 10.2.1.250 -o none
az vm create --name $site2_vnet_name-fw --resource-group $rg --nics $site2_vnet_name-fw-wan $site2_vnet_name-fw-lan --size Standard_B2als_v2 --attach-os-disk $diskId --os-type linux
site2_fw_public_ip=$(az network public-ip show -g $rg -n $site2_vnet_name-fw --query 'ipAddress' -o tsv | tr -d '\r') && echo $site2_vnet_name-fw public ip: $site2_fw_public_ip
site2_fw_wan_private_ip=$(az network nic show -g $rg -n $site2_vnet_name-fw-wan --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site2_vnet_name-fw wan private IP: $site2_fw_wan_private_ip
site2_fw_lan_private_ip=$(az network nic show -g $rg -n $site2_vnet_name-fw-lan --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r') && echo $site2_vnet_name-fw lan private IP: $site2_fw_lan_private_ip

# pfsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $site2_vnet_name-fw...\e[0m"
az vm boot-diagnostics enable -g $rg -n $site2_vnet_name-fw -o none

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

# Follow this documentation to configure pfsense ipsec s2s vpn between the two sites: https://docs.netgate.com/pfsense/en/latest/recipes/ipsec-s2s-psk.html but take the following into account:
# 1. In phase 1, set 'My identifier'/'Peer identifier' to IP address and put the public ip address of each pfsense firewall
# 2. in phase 2, set the 'local network'/'remote network' to network and put the $site1_vnet_address and $site2_vnet_address
# 3. In the IPSec firewall rule, set the 'destination' to 'network' and put the other site vnet address space

# az group delete -n $rg -y --no-wait