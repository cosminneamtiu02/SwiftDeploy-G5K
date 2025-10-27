#!/bin/bash
set -e

cd ~
apt install --yes git build-essential libatlas-base-dev libblas-dev libopenblas-dev liblapack-dev liblapacke-dev cmake
apt update && apt upgrade -y
apt install --yes pkg-config libgtk-3-dev libavcodec-dev libavformat-dev libswscale-dev libv4l-dev libxvidcore-dev libx264-dev libjpeg-dev libpng-dev libtiff-dev gfortran openexr libatlas-base-dev python3-dev python3-numpy libtbb2 libtbb-dev libdc1394-22-dev

mkdir -p ~/opencv_build && cd ~/opencv_build
git clone https://github.com/opencv/opencv.git
git clone https://github.com/opencv/opencv_contrib.git
cd ~/opencv_build/opencv
mkdir build && cd build
cmake -D CMAKE_BUILD_TYPE=RELEASE \
	-D CMAKE_INSTALL_PREFIX=/usr/local \
	-D INSTALL_C_EXAMPLES=OFF \
	-D INSTALL_PYTHON_EXAMPLES=OFF \
	-D OPENCV_GENERATE_PKGCONFIG=ON \
	-D OPENCV_EXTRA_MODULES_PATH=~/opencv_build/opencv_contrib/modules \
	-D BUILD_EXAMPLES=OFF ..
make -j40
make install

cd ~
git clone https://github.com/cosminneamtiu02/csnn_simulator
mkdir -p csnn-build && cd csnn-build
export CMAKE_PREFIX_PATH=\$CMAKE_PREFIX_PATH:~/opencv_build/opencv/build/
cmake ../csnn_simulator -G"Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DUSE_GUI=NO
make

cd ~
git clone https://github.com/cosminneamtiu02/data_CK-.git
mv data_CK- data_CK+
