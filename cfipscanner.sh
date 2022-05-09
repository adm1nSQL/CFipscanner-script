#!/bin/bash
# cloudflare ip test
read -p "请设置RTT测试进程数(默认20,最大100):" tasknum
read -p "是否需要测速[(默认1.是)0.否]:" mode
rm -rf master.zip cloudflare-master
curl https://proxy.freecdn.ml/?url=https://github.com/ip-scanner/cloudflare/archive/refs/heads/master.zip -o master.zip && unzip master.zip && cat cloudflare-master/*.txt | sort -u>ip.txt
rm -rf master.zip cloudflare-master
port=443
if [ -z "$tasknum" ]
then
	tasknum=20
fi
if [ $tasknum -eq 0 ]
then
	echo 进程数不能为0,自动设置为默认值
	tasknum=20
fi
if [ $tasknum -gt 100 ]
then
	echo 超过最大进程限制,自动设置为最大值
	tasknum=100
fi
if [ -z "$mode" ]
then
	mode=1
fi

function colocation (){
curl --ipv4 --retry 3 -s https://speed.cloudflare.com/locations | sed -e 's/},{/\n/g' -e 's/\[{//g' -e 's/}]//g' -e 's/"//g' -e 's/,/:/g' | awk -F: '{print $12","$10"-("$2")"}'>colo.txt
}

function rtt (){
declare -i ms
n=1
for i in `cat rtt/$1.txt`
do
	ip=$i
	curl --resolve www.cloudflare.com:$port:$ip https://www.cloudflare.com:$port/cdn-cgi/trace -s --connect-timeout 1 --max-time 2 -w "timems="%{time_connect}"\n">>rtt/$1-$n.log
	status=$(grep h=www.cloudflare.com rtt/$1-$n.log | wc -l)
	if [ $status == 1 ]
	then
		clientip=$(grep ip= rtt/$1-$n.log | cut -f 2- -d'=')
		colo=$(grep colo= rtt/$1-$n.log | cut -f 2- -d'=')
		location=$(grep $colo colo.txt | awk -F"-" '{print $1}' | awk -F"," '{print $1}')
		country=$(grep loc= rtt/$1-$n.log | cut -f 2- -d'=')
		ms=$(grep timems= rtt/$1-$n.log | awk -F"=" '{printf ("%d\n",$2*1000)}')
		if [[ "$clientip" == "$publicip" ]]
		then
			clientip=0.0.0.0
			ipstatus=官方
		elif [[ "$clientip" == "$ip" ]]
		then
			ipstatus=中转
		else
			ipstatus=隧道
		fi
		echo $ip,$port,$clientip,$country,$location,$ipstatus,$ms ms>rtt/$1-$n.log
	else
		rm -rf rtt/$1-$n.log
	fi
	n=$[$n+1]
done
rm -rf rtt/$1.txt
}

function speedtest (){
curl --resolve speed.cloudflare.com:$2:$1 https://speed.cloudflare.com:$2/__down?bytes=300000000 -o /dev/null --connect-timeout 2 --max-time 5 -w "HTTPCODE"_%{http_code}"\n"> log.txt 2>&1
status=$(cat log.txt | grep HTTPCODE | awk -F_ '{print $2}')
if [ $status == 200 ]
then
	cat log.txt | tr '\r' '\n' | awk '{print $NF}' | sed '1,3d;$d' | grep -v 'k\|M\|received' >> speed.txt
	for i in `cat log.txt | tr '\r' '\n' | awk '{print $NF}' | sed '1,3d;$d' | grep k | sed 's/k//g'`
	do
		declare -i k
		k=$i
		k=k*1024
		echo $k >> speed.txt
	done
	for i in `cat log.txt | tr '\r' '\n' | awk '{print $NF}' | sed '1,3d;$d' | grep M | sed 's/M//g'`
	do
		i=$(echo | awk '{print '$i'*10 }')
		declare -i M
		M=$i
		M=M*1024*1024/10
		echo $M >> speed.txt
	done
	declare -i max
	max=0
	for i in `cat speed.txt`
	do
		if [ $i -ge $max ]
		then
			max=$i
		fi
	done
else
	max=0
fi
rm -rf log.txt speed.txt
echo $max
}

function cloudflaretest (){
rm -rf rtt data.txt speed.txt
mkdir rtt
declare -i ipnum
declare -i iplist
declare -i n
publicip=$(curl --ipv4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -f 2- -d'=')
ipnum=$(cat ip.txt | wc -l)
if [ $ipnum == 0 ]
then
	echo 当前没有任何IP
	exit
fi
if [ $ipnum -lt $tasknum ]
then
	tasknum=ipnum
fi
iplist=ipnum/tasknum
declare -i a=1
declare -i b=1
for i in `cat ip.txt`
do
	echo $i>>rtt/$b.txt
	if [ $a == $iplist ]
	then
		a=1
		b=b+1
	else
		a=a+1
	fi
done
if [ $a != 1 ]
then
	a=1
	b=b+1
fi
while true
do
	if [ $a == $b ]
	then
		break
	else
		rtt $a &
	fi
	a=a+1
done
while true
do
	sleep 2
	n=$(ls rtt | grep txt | grep -v "grep" | wc -l)
	if [ $n -ne 0 ]
	then
		echo 等待RTT测试结束,剩余进程数 $n
	else
		echo RTT测试完成
		break
	fi
done
}

if [ ! -f "colo.txt" ]
then
	echo 生成colo.txt
	colocation
else
	echo colo.txt 已存在,跳过此步骤!
fi
echo 开始检测IP有效性
cloudflaretest
ipnum=$(ls rtt | wc -l)
if [ $ipnum == 0 ]
then
	echo 当前没有任何有效IP
	exit
fi
if [ $mode == 1 ]
then
	echo 中转IP,中转端口,回源IP,国家,数据中心,IP类型,网络延迟,等效带宽,峰值速度>anycast-speedtest.csv
	for i in `cat rtt/*.log | sed -e 's/ /_/g'`
	do
		ip=$(echo $i | awk -F, '{print $1}')
		port=$(echo $i | awk -F, '{print $2}')
		clientip=$(echo $i | awk -F, '{print $3}')
		if [ $clientip != 0.0.0.0 ]
		then
			echo 正在测试 $ip 端口 $port
			maxspeed=$(speedtest $ip $port)
			maxspeed=$[$maxspeed/1024]
			maxbandwidth=$[$maxspeed/128]
			echo $ip 等效带宽 $maxbandwidth Mbps 峰值速度 $maxspeed kB/s
			if [ $maxspeed == 0 ]
			then
				echo 重新测试 $ip 端口 $port
				maxspeed=$(speedtest $ip $port)
				maxspeed=$[$maxspeed/1024]
				maxbandwidth=$[$maxspeed/128]
				echo $ip 等效带宽 $maxbandwidth Mbps 峰值速度 $maxspeed kB/s
			fi
		else
			echo 跳过测试 $ip 端口 $port
			maxspeed=null
			maxbandwidth=null
		fi
		if [ $maxspeed != 0 ]
		then
			echo $i,$maxbandwidth Mbps,$maxspeed kB/s | sed -e 's/_/ /g'>>anycast-speedtest.csv
		fi
	done
	rm -rf rtt
	echo anycast-speedtest.csv 已经生成
else
	echo 中转IP,中转端口,回源IP,国家,数据中心,IP类型,网络延迟>anycast.csv
	cat rtt/*.log>>anycast.csv
	echo anycast.csv 已经生成
	rm -rf rtt
fi
