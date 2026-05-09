How to modify stock image to launch spruce:

```
sudo losetup -Pf RG35XXSP-V1.1.4-EN16GB-251225.IMG

sudo mkdir -p /mnt/appfs
sudo mkdir -p /mnt/roms
sudo mount /dev/loop0p6 /mnt/appfs
sudo mount /dev/loop0p1 /mnt/roms
sudo rm -rf /mnt/roms/PDF/*
sudo rm -rf /mnt/roms/Music/*
sudo rm -rf /mnt/roms/Video/*

vi /mnt/appfs/ctrl/loadapp.sh
```

Edit from this comment down to look like this:
```
#---- third mod need this to mount sdcard ---
/mnt/vendor/ctrl/mmc_new.sh add

if [ -f "/mnt/mod/ctrl/autostart" ]; then
        /mnt/mod/ctrl/autostart
fi


# Set /mnt/SDCARD to the best available target
if [ -e "/mnt/sdcard" ]; then
    ln -sf /mnt/sdcard /mnt/SDCARD
elif [ -e "/mnt/mmc" ]; then
    ln -sf /mnt/mmc /mnt/SDCARD
fi

# Override if updater exists
if [ -f "/mnt/SDCARD/.tmp_update/anbernic.sh" ]; then
    RunBin="/mnt/SDCARD/.tmp_update/anbernic.sh"
fi


while [ -f $RunBin ]
do
        if [ -f $StopBin ];then
                echo "stop app run ..."
                #systemctl stop NetworkManager.service
                break
        fi

        $RunBin
done
```                              

Then unmount
```
 sudo umount /mnt/appfs
 sudo umount /mnt/roms
 sudo losetup -D
```
