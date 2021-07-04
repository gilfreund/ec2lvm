A Script to mount EC2 ephemeral storage instance as an LVM volume, optionally adding and EBS if the needed storage is not sufficient. 

This can potentially mix Ephemeral and EBS devices, so performance will be at storage instance level, and will not survive shutdown / reboots. 

There are several assumptions in the code:
* I don't trust the data from meta-data/block-device-mapping, so I search for actual devices. 
* All devices, apart from the boot device can be used. 
* I am assuming boot device name by OS

I am using LVM and xfs. 

