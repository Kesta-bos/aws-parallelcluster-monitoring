#!/bin/bash -i
#
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
#

#source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

yum -y install docker
service docker start
chkconfig docker on
usermod -a -G docker $cfn_cluster_user

#to be replaced with yum -y install docker-compose as the repository problem is fixed
curl -L "https://github.com/docker/compose/releases/download/1.27.4/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

github_repo=$(echo ${cfn_postinstall_args}| cut -d ',' -f 1 )
setup_command=$(echo ${cfn_postinstall_args}| cut -d ',' -f 2 )
monitoring_dir_name=$(basename -s .git ${github_repo})

case "${cfn_node_type}" in
	MasterServer)

		#Unsupported
		#cfn_efs=$(cat /etc/chef/dna.json | grep \"cfn_efs\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		#cfn_cluster_cw_logging_enabled=$(cat /etc/chef/dna.json | grep \"cfn_cluster_cw_logging_enabled\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		cfn_fsx_fs_id=$(cat /etc/chef/dna.json | grep \"cfn_fsx_fs_id\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")

		#Supported
		master_instance_id=$(ec2-metadata -i | awk '{print $2}')
		cfn_max_queue_size=$(aws cloudformation describe-stacks --stack-name $stack_name --region $cfn_region | jq -r '.Stacks[0].Parameters | map(select(.ParameterKey == "MaxSize"))[0].ParameterValue')
		s3_bucket=$(echo $cfn_postinstall | sed "s/s3:\/\///g;s/\/.*//")

		yum -y install golang-bin 

		chown $cfn_cluster_user:$cfn_cluster_user -R /home/$cfn_cluster_user
		chmod +x /home/${cfn_cluster_user}/${monitoring_dir_name}/custom-metrics/* 

		cp -rp /home/${cfn_cluster_user}/${monitoring_dir_name}/custom-metrics/* /usr/local/bin/
		mv /home/${cfn_cluster_user}/${monitoring_dir_name}/prometheus-slurm-exporter/slurm_exporter.service /etc/systemd/system/

	 	(crontab -l -u $cfn_cluster_user; echo "*/1 * * * * /usr/local/bin/1m-cost-metrics.sh") | crontab -u $cfn_cluster_user -
		(crontab -l -u $cfn_cluster_user; echo "*/60 * * * * /usr/local/bin/1h-cost-metrics.sh") | crontab -u $cfn_cluster_user - 


		# replace tokens 
		sed -i "s/_S3_BUCKET_/${s3_bucket}/g"               /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/ParallelCluster.json
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/ParallelCluster.json 
		sed -i "s/__FSX_ID__/${cfn_fsx_fs_id}/g"            /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/ParallelCluster.json
		sed -i "s/__AWS_REGION__/${cfn_region}/g"           /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/ParallelCluster.json 

		sed -i "s/__AWS_REGION__/${cfn_region}/g"           /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/logs.json 

		sed -i "s/__Application__/${stack_name}/g"          /home/${cfn_cluster_user}/${monitoring_dir_name}/prometheus/prometheus.yml 

		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/master-node-details.json
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/compute-node-list.json 
		sed -i "s/__INSTANCE_ID__/${master_instance_id}/g"  /home/${cfn_cluster_user}/${monitoring_dir_name}/grafana/dashboards/compute-node-details.json 

		sed -i "s/__MONITORING_DIR__/${monitoring_dir_name}/g"  /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.master.yml

		#Generate selfsigned certificate for Nginx over ssl
		nginx_dir="/home/${cfn_cluster_user}/${monitoring_dir_name}/nginx"
		nginx_ssl_dir="${nginx_dir}/ssl"
		mkdir -p ${nginx_ssl_dir}
		echo -e "\nDNS.1=$(ec2-metadata -p | awk '{print $2}')" >> "${nginx_dir}/openssl.cnf"
		openssl req -new -x509 -nodes -newkey rsa:4096 -days 3650 -keyout "${nginx_ssl_dir}/nginx.key" -out "${nginx_ssl_dir}/nginx.crt" -config "${nginx_dir}/openssl.cnf"

		#give $cfn_cluster_user ownership 
		chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.key"
		chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.crt"

		/usr/local/bin/docker-compose --env-file /etc/parallelcluster/cfnconfig -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.master.yml -p grafana-master up -d

		# Download and build prometheus-slurm-exporter 
		##### Plese note this software package is under GPLv3 License #####
		# More info here: https://github.com/vpenso/prometheus-slurm-exporter/blob/master/LICENSE
		cd /home/${cfn_cluster_user}/${monitoring_dir_name}
		git clone https://github.com/vpenso/prometheus-slurm-exporter.git
		cd prometheus-slurm-exporter
		GOPATH=/root/go-modules-cache HOME=/root go mod download
		GOPATH=/root/go-modules-cache HOME=/root go build
		mv /home/${cfn_cluster_user}/${monitoring_dir_name}/prometheus-slurm-exporter/prometheus-slurm-exporter /usr/bin/prometheus-slurm-exporter

		systemctl daemon-reload
		systemctl enable slurm_exporter
		systemctl start slurm_exporter
	;;

	ComputeFleet)
	
		/usr/local/bin/docker-compose -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.compute.yml -p grafana-compute up -d

	;;
esac