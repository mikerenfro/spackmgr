# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "bento/rockylinux-8"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 16384
    vb.cpus = 4
  end
  config.vm.provision "shell", inline: <<-SHELL
    yum -y install gcc gcc-c++ gcc-gfortran git patch epel-release
    crb enable
    yum -y install slurm
  SHELL
end
