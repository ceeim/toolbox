#!/bin/bash

start_time=$(date +%s)

# 隐藏具体输出，只显示安装步骤或报错，并具有等待标识
function display_message() {
  echo -e "\n>> $1"
  echo -e "----------------------------------------\n"
}

# 获取OLS版本号
display_message "正在获取 OpenLiteSpeed 版本号"
OLS_VER=$(curl -s https://cyberpanel.sh/openlitespeed.org/packages/release)
display_message "OpenLiteSpeed 最新版本号: $OLS_VER"

# 获取服务器 IP 和国家
display_message "正在获取服务器 IP 和地区"
IP=$(curl -s ipinfo.io/ip)
COUNTRY=$(curl -s ipinfo.io/country)

# 根据国家选择安装方式和下载链接
if [ "$COUNTRY" = "CN" ]; then
  display_message "服务器地区为（$COUNTRY），将使用加速软件源安装 OpenLiteSpeed"
  display_message "正在安装软件源"
  curl -sS http://cyberpanel.sh/rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh | bash
  sudo sed -i 's/rpms.litespeedtech.com/cyberpanel.sh\/rpms.litespeedtech.com/' /etc/apt/sources.list.d/lst_debian_repo.list
  sudo apt-get update -y
  display_message "正在下载 OpenLiteSpeed 安装包"
  wget -q "https://cyberpanel.sh/openlitespeed.org/packages/openlitespeed-${OLS_VER}.tgz"
else
  display_message "服务器地区为（$COUNTRY），将使用官方软件源安装 OpenLiteSpeed"
  display_message "正在安装软件源"
  curl -sS http://rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh | bash
  display_message "正在下载 OpenLiteSpeed 安装包"
  wget -q "https://openlitespeed.org/packages/openlitespeed-${OLS_VER}.tgz"
fi

# 安装 OpenLiteSpeed
display_message "正在安装 OpenLiteSpeed"
tar xf "openlitespeed-${OLS_VER}.tgz"
cd "openlitespeed*"
sudo ./install.sh

# 使用软件源安装 lsphp74 lsphp74-* lsphp81 lsphp81-* lsphp82 lsphp82-*
display_message "正在安装 LSPHP"
sudo apt-get install -y lsphp74 lsphp74-* lsphp81 lsphp81-* lsphp82 lsphp82-*

# 打印控制台地址和默认用户名密码
display_message "OpenLiteSpeed 安装完成"
echo -e "控制台地址: http://$IP:7080"

end_time=$(date +%s)
duration=$((end_time - start_time))

# 询问是否更改默认密码
read -p "是否更改默认密码？(y/n): " change_password
if [ "$change_password" = "y" ] || [ "$change_password" = "Y" ]; then
  sudo /usr/local/lsws/admin/misc/admpass.sh
fi

# 显示总用时
display_message "全部设置已完成"
echo -e "\n脚本总用时：$((duration / 60)) 分钟"
