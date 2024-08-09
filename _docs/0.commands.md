apt update
apt install sudo
useradd -m -s /bin/bash aniket
passwd aniket
usermod -aG sudo aniket
