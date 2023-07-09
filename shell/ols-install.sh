#!/bin/bash
# Author: Cee
# Website: https://cee.im

start_time=$(date +%s)

function display_message() {
  echo -e "\n>> $1"
  echo -e "----------------------------------------\n"
}

display_message "正在获取 OpenLiteSpeed 版本号"
OLS_VER=$(curl -s https://cyberpanel.sh/openlitespeed.org/packages/release)
display_message "OpenLiteSpeed 最新版本号: $OLS_VER"

display_message "正在获取服务器 IP 和地区"
IP=$(curl -s ipinfo.io/ip)
COUNTRY=$(curl -s ipinfo.io/country)

if [ "$COUNTRY" = "CN" ]; then
  display_message "服务器地区为（$COUNTRY），将使用加速软件源安装 OpenLiteSpeed"
  mkdir -p /usr/local/lsws/admin/misc > /dev/null 2>&1
  wget -q -O /usr/local/lsws/admin/misc/lsup.sh https://ghproxy.com/https://raw.githubusercontent.com/ceeim/toolbox/master/shell/lsup.sh > /dev/null 2>&1
  chmod +x /usr/local/lsws/admin/misc/lsup.sh
  display_message "正在安装软件源"
  curl -sS http://cyberpanel.sh/rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh | bash >/dev/null
  sudo sed -i 's/rpms.litespeedtech.com/cyberpanel.sh\/rpms.litespeedtech.com/' /etc/apt/sources.list.d/lst_debian_repo.list
  sudo apt-get update -y >/dev/null
  display_message "正在下载 OpenLiteSpeed 安装包"
  wget -q "https://cyberpanel.sh/openlitespeed.org/packages/openlitespeed-${OLS_VER}.tgz" -P ~/
else
  display_message "服务器地区为（$COUNTRY），将使用官方软件源安装 OpenLiteSpeed"
  display_message "正在安装软件源"
  curl -sS http://rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh | bash >/dev/null
  display_message "正在下载 OpenLiteSpeed 安装包"
  wget -q "https://openlitespeed.org/packages/openlitespeed-${OLS_VER}.tgz" -P ~/
fi

display_message "正在安装 OpenLiteSpeed"
tar xf "${HOME}/openlitespeed-${OLS_VER}.tgz"
cd "${HOME}/openlitespeed"
sudo ./install.sh

display_message "正在安装 LSPHP"
sudo apt-get install -y lsphp74 lsphp74-* lsphp80 lsphp80-* lsphp81 lsphp81-* lsphp82 lsphp82-* >/dev/null

display_message "OpenLiteSpeed 安装完成"
echo -e "控制台地址: https://$IP:7080"
sudo cat /usr/local/lsws/adminpasswd

end_time=$(date +%s)
duration=$((end_time - start_time))
hours=$((duration / 3600))
minutes=$(( (duration % 3600) / 60 ))
seconds=$((duration % 60))

read -p "是否更改默认用户名/密码？(y/n): " change_password
if [ "$change_password" = "y" ] || [ "$change_password" = "Y" ]; then
  sudo /usr/local/lsws/admin/misc/admpass.sh
fi
sudo systemctl restart lsws

display_message "安装总用时：$hours 小时 $minutes 分钟 $seconds 秒"

rm -rf ${HOME}/openlitespeed*
