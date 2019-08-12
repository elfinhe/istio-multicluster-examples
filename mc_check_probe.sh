#!/bin/bash -e

source ./common.sh

echo -e "\n [*] install a fortio probe in ${KUBECONTEXT1}... \n"
install_probe "$KUBECTL1"
echo -e "\n [OK] install a fortio probe in ${KUBECONTEXT1}\n"

echo -e "\n [*] install a fortio probe in ${KUBECONTEXT2}... \n"
install_probe "$KUBECTL2"
echo -e "\n [OK] install a fortio probe in ${KUBECONTEXT2}\n"

echo -e "\n [*] check if Cluster 1 fortio can access both fortio servers in 2 clusters... \n"
check_probe_load_balancer "$KUBECTL1" "$KUBECTL2"
echo -e "\n [OK] check if Cluster 1 fortio can access both fortio servers in 2 clusters... \n"

echo -e "\n [*] uninstall the fortio probe in $($KUBECTL1 config current-context)... \n"
delete_probe  "$KUBECTL1"
echo -e "\n [OK] uninstall the fortio probe in $($KUBECTL1 config current-context)\n"

echo -e "\n [*] uninstall the fortio probe in $($KUBECTL2 config current-context)... \n"
delete_probe  "$KUBECTL2"
echo -e "\n [OK] uninstall the fortio probe in $($KUBECTL2 config current-context)\n"
