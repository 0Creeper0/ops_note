#!/bin/bash

#自动配置mysqlAB复制

echo '部署mysqlAB复制脚本'
read -p '请输入master ip: ' master_ip
read -p '请输入slave ip: ' slave_ip

#建立互信
ssh(){
	/usr/bin/expect << EOF
	set timeout 300
	spawn ssh-keygen
	expect (/root/.ssh/id_rsa):
	send \r
	expect passphrase): 
	send \r
	expect again:
	send \r
	spawn ssh-copy-id -i 192.168.16.128
	expect (yes/no)?
	send yes\r
	expect password:
	send 123\r
	spawn scp -r /root/.ssh $master_ip:/root
	expect (yes/no)?
	send yes\r
	expect password:
	send 123\r
	spawn scp -r /root/.ssh $slave_ip:/root
	expect (yes/no)?
	send yes\r
	expect password:
	send 123\r
	expect eof
EOF
echo '1' &> /dev/null
}

#ssh到目标ip,完成mysql源码包安装部署并修改mysql的root密码为123
install_mysql(){
	id1=`echo $1 | awk -F. '{print $1$2$3$4}'`
	id2=`echo $master_ip | awk -F. '{print $1$2$3$4}'`
	id3=`echo $slave_ip | awk -F. '{print $1$2$3$4}'`
	if [ $id1 -eq $id2 ]
	then
		id=`echo $master_ip | awk -F. '{print $NF}'`
	fi
	if [ $id1 -eq $id3 ]
	then
		id=`echo $slave_ip | awk -F. '{print $NF}'`
	fi
	echo $id
	sleep 3
	/usr/bin/expect <<EOF
	set timeout 300
	spawn ssh $1
	expect *#
	send {wget -O /tmp/mysql57.tar.gz ftp://192.168.16.128/mysql/mysql57.tar.gz}
	send \r
	expect *#
	send {tar -xvf /tmp/mysql57.tar.gz -C /usr/local}
	send \r
	expect *#
	send {echo "export PATH=/usr/local/mysql/bin:$PATH" >> /etc/profile}
	send \r
	expect *#
	send {source /etc/profile}
	send \r
	expect *#
	send {groupadd -g 27 mysql}
	send \r
	expect *#
	send {useradd -M -u 27 -g 27 -s /sbin/nologin mysql}
	send \r
	expect *#
	send {cat > /etc/my.cnf <<EOF
	[mysql]
	socket=/usr/local/mysql/mysql.sock
	[mysqld]
	socket=/usr/local/mysql/mysql.sock
	server-id=$id
	EOF
	}
	send \r
	expect *#
	send {\cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysqldd}
	send \r
	expect *#
	send {chkconfig --add mysqldd}
	send \r
	expect *#
	send {rm -rf /usr/local/mysql/data}
	send \r
	expect *#
	send {/usr/local/mysql/bin/mysqld --initialize --user=mysql --datadir=/usr/local/mysql/data &> /tmp/data.data}
	send \r
	expect *#
	send {pass=\`awk '/root@localhost/{print \$NF}' /tmp/data.data\`}
	send \r
	expect *#
	send {chown -R mysql.mysql /usr/local/mysql}
	send \r
	expect *#
	send {pkill mysqld}
	send \r
	expect *#
	send {systemctl restart mysqldd}
	send \r
	expect *#
	send {mysql -u root -p\$pass}
	send \r
	expect *>
	send {set password='123';}
	send \r
	expect *>
	send exit\r
	expect *#
	send exit\r
	expect eof
	exit
EOF
echo '1'&>/dev/null
}

#master全备份,将全备拷贝到slave并且slave恢复备份
backup(){
	/usr/bin/expect << EOF
	spawn ssh $master_ip
	expect *#
	send {mysqldump -u root -p123 -S /usr/local/mysql/mysql.sock --all-databases >> /tmp/all_\$(date +%F).sql}
	send \r
	expect *#
	send {scp /tmp/all_\$(date +%F).sql $slave_ip:/tmp/}
	send \r
	expect *#
	send {ssh $slave_ip}
	send \r
	expect *#
	send {mysql -u root -p123 < /tmp/all_\$(date +%F).sql}
	send \r
	expect *#
	send exit\r
	expect *#
	send exit\r
	expect eof
EOF
echo '1'&>/dev/null
}

#修改master的my.cnf开启binlog
modify_my_cnf_binlog(){
	/usr/bin/expect<<EOF
	set timeout 300
	spawn ssh $master_ip
	expect *#
	send {echo -e "log-bin=/backup/binlog/master\nlog-bin-index=/backup/binlog/master" >> /etc/my.cnf}
	send \r
	expect *#
	send {pkill mysqld}
	send \r
	expect *#
	send {systemctl restart mysqldd}
	send \r
	expect *#
	send exit\r
	expect eof	
EOF
echo '1'&>/dev/null
}
#master给slave授权,slave设置master信息
grant_config(){
	ls
	/usr/bin/expect << EOF
	spawn ssh $master_ip
	expect *#
	send {mysql -u root -p123}
	send \r
	expect *>
	send {grant replication slave on *.* to slave@'$slave_ip' identified by '123';}
	send \r
	expect *>
	send exit\r
	expect *#
	send {mysql -u root -p123 -e "show master status\G" 2>/dev/null | awk -F' ' '/File|Position/{print \$0}' > /tmp/pos}
	send \r
	expect *#
	send {scp /tmp/pos $slave_ip:/tmp}
	send \r
	expect *#
	send exit\r
	spawn ssh $slave_ip
	expect *#
	send {file=\`awk '/File/{print \$2}' /tmp/pos\`}
	send \r
	expect *#
	send {pos=\`awk '/Position/{print \$2}' /tmp/pos\`}
	send \r
	expect *#
	send {mysql -u root -p123 -e "stop slave; change master to master_host='$master_ip',master_user='slave',master_password='123',master_port=3306,master_log_file='\$file',master_log_pos=\$pos;start slave;"}
	send \r
	expect *#
	send {mysql -u root -p123 -e "show slave status\G"}
	send \r
	expect *#
	send exit\r
	expect eof
EOF
echo '1'&>/dev/null
}

if ping -c 1 $master_ip &> /dev/null
then
	if ping -c 1 $slave_ip &> /dev/null
	then
		echo "master&slave ok" #两个ip全通
		ssh #建立互信
		if install_mysql $master_ip
		then
			echo "master success"
			if install_mysql $slave_ip
			then
				if backup	#备份同步两主机
				then
					echo "备份同步完成"
				else
					echo "备份同步失败"
				fi

				if modify_my_cnf_binlog #修改master的my.cnf开启binlog
				then
					echo "master binlog 开启成功"
				else
					echo "master binlog 开启失败"
				fi
				if grant_config
				then
					echo "授权及配置成功"
				else
					echo "授权及配置失败"
				fi
			fi
		#rm -rf /root/.ssh
		fi
	else
		echo "slave lost"
	fi
	else
		echo "master lost"
fi
