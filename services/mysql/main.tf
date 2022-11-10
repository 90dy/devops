# cf. https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/
# cf. https://github.com/mariadb-corporation/MaxScale/blob/2.2/Documentation/Tutorials/MaxScale-Tutorial.md
# cf. https://mariadb.com/kb/en/setting-up-replication/
# cf. https://github.com/mariadb-corporation/MaxScale/blob/2.2/Documentation/Tutorials/Read-Write-Splitting-Tutorial.md

variable "namespace" {
	type = string
}
variable "host" {
	type = string
}
variable "root_password" {
	type = string
	default = ""
}

variable "min_replicas" {
	type = number
	default = 2
}
variable "max_replicas" {
	type		= number
	default = 5
}
variable "storage_size" {
	type = string
	default = "1Gi"
}
# Permit external-dns to handle host
resource "kubernetes_ingress_v1" "mysql" {
	metadata {
		namespace = var.namespace
		name			= "mysql"
	}
	spec {
		rule {
			host = var.host
		}
	}
}
# IngressRoute resource is custom to traefik
resource "kubernetes_manifest" "mysql" {
	manifest = yamldecode(replace(<<-EOF
		apiVersion: traefik.containo.us/v1alpha1
		kind: IngressRouteTCP
		metadata:
			namespace: default
			name: mysql
		spec:
			entryPoints: [mysql]
			routes:
			- services:
				- name: mysql
					port: 3306
				match: HostSNI(`*`)
	EOF
	, "\t", "  "))
}
# Headless service for stable DNS entries of StatefulSet members.
resource "kubernetes_service" "mysql" {
	depends_on = [
		kubernetes_config_map.mariadb
	]
	metadata {
		namespace = var.namespace
		name			= "mysql"
	}
	spec {
		port {
			name = "maxscale"
			port = 3306
			target_port = 4008
		}
		selector = {
			app = "mysql"
		}
	}
}
resource "kubernetes_config_map" "mariadb" {
	depends_on = [
	]
	metadata {
		namespace = var.namespace
		name			= "mariadb"
		annotations = {
			"max_replicas" = "${var.max_replicas}"
			"root_password": "${sha256(var.root_password)}"
		}
	}
	data = {
		"primary.cnf"	= <<-EOF
			# Apply this config only on the primary.
			[mariadb]
			log-bin
			log-basename=mysql
			binlog-format=mixed
		EOF
		"replica.cnf" = <<-EOF
			# Apply this config only on replicas.
			[mariadb]
			read-only
		EOF
		"maxscale.cnf" = <<-EOF
			# cf. https://severalnines.com/blog/mariadb-maxscale-load-balancing-docker-deployment-part-one/#:~:text=Port%20to%20listen%20by%20MaxScale,for%20read%2Dwrite%20split%20connections.

			########################
			## Server list
			########################

			${join("", [for id in range(0, var.max_replicas) :
				<<-EOF
					[mariadb-${id}]
					type            = server
					host            = mariadb-${id}.mysql
					port            = 3306
					protocol        = MariaDBBackend
					serv_weight     = 1
				EOF
			])}

			#########################
			## MaxScale configuration
			#########################

			[maxscale]
			threads                 = auto
			log_augmentation        = 1
			ms_timestamp            = 1
			syslog                  = 1
			admin_enabled           = true

			#########################
			# Monitor for the servers
			#########################

			[monitor]
			type                    = monitor
			module                  = mariadbmon
			servers         				= ${join(",", [for id in range(0, var.max_replicas) : "mariadb-${id}"])}
			user                    = root
			password                = ${var.root_password}
			auto_failover           = true
			auto_rejoin             = true
			enforce_read_only_slaves = 1

			#########################
			## Service definitions for read/write splitting and read-only services.
			#########################

			[rw-service]
			type            = service
			router          = readwritesplit
			servers         = ${join(",", [for id in range(0, var.max_replicas) : "mariadb-${id}"])}
			user            = root
			password        = ${var.root_password}
			max_slave_connections           = 100%
			max_sescmd_history              = 1500
			causal_reads                    = true
			causal_reads_timeout            = 10
			transaction_replay              = true
			transaction_replay_max_size     = 1Mi
			delayed_retry                   = true
			master_reconnection             = true
			master_failure_mode             = fail_on_write
			max_slave_replication_lag       = 3

			[rr-service]
			type            = service
			router          = readconnroute
			servers         = ${join(",", [for id in range(0, var.max_replicas) : "mariadb-${id}"])}
			router_options  = slave
			user            = root
			password        = ${var.root_password}

			##########################
			## Listener definitions for the service
			## Listeners represent the ports the service will listen on.
			##########################

			[rw-listener]
			type            = listener
			service         = rw-service
			protocol        = MariaDBClient
			port            = 4008

			[ro-listener]
			type            = listener
			service         = rr-service
			protocol        = MariaDBClient
			port            = 4006
		EOF
	}
}
resource "kubernetes_stateful_set" "mariadb" {
	depends_on = [
		kubernetes_service.mysql,
		kubernetes_config_map.mariadb,
	]
	metadata {
		namespace = var.namespace
		name			= "mariadb"
		labels = {
			"app" = "mysql"
		}
	}
	spec {
		service_name = "mysql"
		replicas		 = var.min_replicas
		selector {
			match_labels = {
				"app" = "mysql"
			}
		}
		template {
			metadata {
				labels = {
					app = "mysql"
				}
			}
			spec {
				init_container {
					name	= "init-mariadb"
					image = "mariadb:10.9"
					volume_mount {
						name			 = "conf-d"
						mount_path = "/mnt/conf.d"
					}
					volume_mount {
						name			 = "config-map"
						mount_path = "/mnt/config-map"
					}
					command = [
						"bash",
						"-c",
						<<-EOF
							set -ex

							echo "Generate mysql server-id from pod ordinal index."
							[[ $HOSTNAME =~ -([0-9]+)$ ]] || exit 1
							ordinal=$${BASH_REMATCH[1]}
							echo [mariadb] > /mnt/conf.d/server-id.cnf

							echo "Add an offset to avoid reserved server-id=0 value."
							echo server-id=$((100 + $ordinal)) >> /mnt/conf.d/server-id.cnf

							echo "Copy appropriate conf.d files from config-map to emptyDir."
							if [[ $ordinal -eq 0 ]]; then
								cp /mnt/config-map/primary.cnf /mnt/conf.d/
							else
								cp /mnt/config-map/replica.cnf /mnt/conf.d/
							fi
						EOF
					]
				}
				init_container {
					name	= "clone-mariadb"
					image = "mariadb:10.9"
					command = [
						"bash",
						"-c",
						<<-EOF
							set -ex

							echo "Skip the clone if data already exists."
							[[ -d /var/lib/mysql/mysql ]] && exit 0

	 						echo "Skip the clone on primary (ordinal index 0)."
							[[ `hostname` =~ -([0-9]+)$ ]] || exit 1
							ordinal=$${BASH_REMATCH[1]}
							[[ $ordinal -eq 0 ]] && exit 0

							apt-get update \
								&& apt-get install -y ncat \
								&& apt-get clean autoclean \
								&& apt-get autoremove --yes \
								&& rm -rf /var/lib/{apt,dpkg,cache,log}/

							echo "Clone data from previous peer."
							ncat --recv-only mariadb-$(($ordinal-1)).mysql 3307 | mbstream -x -C /var/lib/mysql

							echo "Prepare the backup."
							mariabackup --prepare --target-dir=/var/lib/mysql
						EOF
					]
					volume_mount {
						name			 = "data"
						mount_path = "/var/lib/mysql"
						sub_path	 = "mysql"
					}
					volume_mount {
						name			 = "conf-d"
						mount_path = "/etc/mysql/conf.d"
					}
				}
				container {
					name	= "maxscale"
					image = "mariadb/maxscale:22.08.2"
					port {
						name					 = "maxscale"
						container_port = 4008
					}
					volume_mount {
						name = "config-map"
						mount_path = "/etc/maxscale.cnf"
						sub_path = "maxscale.cnf"
					}
				}
				container {
					name	= "mariadb"
					image = "mariadb:10.9"
					env {
						name = var.root_password == "" ? "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD" : "MARIADB_ROOT_PASSWORD"
						value = var.root_password == "" ? "yes" : var.root_password
					}
					port {
						name = "mariadb"
						container_port = 3306
					}
					volume_mount {
						name			 = "conf-d"
						mount_path = "/etc/mysql/conf.d"
					}
					volume_mount {
						name			 = "data"
						mount_path = "/var/lib/mysql"
						sub_path	 = "mysql"
					}
					volume_mount {
						name = "mysqld"
						mount_path = "/run/mysqld"
					}
					resources {
						requests = {
							"cpu"		= "500m"
							"memory" = "1Gi"
						}
					}
					liveness_probe {
						exec {
							command = ["mysqladmin", "ping"]
						}
						initial_delay_seconds = 30
						period_seconds				= 30
						timeout_seconds			 = 5
					}
					readiness_probe {
						exec {
							command = ["mysql", "-e", "SELECT 1"]
						}
						initial_delay_seconds = 5
						period_seconds				= 2
						timeout_seconds			 = 1
					}
					startup_probe {
						exec {
							command = ["mysql", "-e",
								<<-EOF
									CREATE USER IF NOT EXISTS 'root'@'%';
									ALTER USER 'root'@'%' IDENTIFIED BY '${var.root_password}';
									GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
									GRANT PROXY ON ''@'%' TO 'root'@'%' WITH GRANT OPTION;
								EOF
							]
						}
					}
				}
				container {
					name	= "mariabackup"
					image = "mariadb:10.9"
					port {
						name					 = "mariabackup"
						container_port = 3307
					}
					command = [
						"bash",
						"-c",
						<<-EOF
	 						set -ex
	 						cd /var/lib/mysql

	 						echo "Determine binlog position of cloned data, if any."
	 						if [[ -f xtrabackup_slave_info && "x$(<xtrabackup_slave_info)" != "x" ]]; then
	 							echo "MariaBackup already generated a partial 'CHANGE MASTER TO' query"
	 							echo "because we're cloning from an existing replica. (Need to remove the tailing semicolon!)"
	 							cat xtrabackup_slave_info | sed -E 's/;$//g' > change_master_to.sql.in
	 							echo "Ignore xtrabackup_binlog_info in this case (it's useless)."
	 							rm -f xtrabackup_slave_info xtrabackup_binlog_info
	 						elif [[ -f xtrabackup_binlog_info ]]; then
	 							echo "We're cloning directly from primary. Parse binlog position."
	 							[[ `cat xtrabackup_binlog_info` =~ ^(.*?)[[:space:]]+(.*?)[[:space:]]+(.*?)$ ]] || exit 1
	 							rm -f xtrabackup_binlog_info xtrabackup_slave_info
	 							echo "CHANGE MASTER TO MASTER_LOG_FILE='$${BASH_REMATCH[1]}', MASTER_LOG_POS=$${BASH_REMATCH[2]}" > change_master_to.sql.in
	 						fi

	 						echo "Check if we need to complete a clone by starting replication."
	 						if [[ -f change_master_to.sql.in ]]; then
	 							echo "Waiting for mysqld to be ready (accepting connections)"
								until mysql -e "SELECT 1"; do sleep 1; done

	 							echo "Initializing replication from clone position"
								mysql \
	 								-e "$(<change_master_to.sql.in), \
	 									MASTER_HOST='mariadb-0.mysql', \
	 									MASTER_USER='root', \
	 									MASTER_PASSWORD='${var.root_password}', \
	 									MASTER_CONNECT_RETRY=10; \
	 									START SLAVE;" || exit 1
	 							echo "In case of container restart, attempt this at-most-once."
	 							mv change_master_to.sql.in change_master_to.sql.orig
	 						fi

							apt-get update \
								&& apt-get install -y ncat \
								&& apt-get clean autoclean \
								&& apt-get autoremove --yes \
								&& rm -rf /var/lib/{apt,dpkg,cache,log}/

	 						echo "Start a server to send backups when requested by peers."
	 						exec ncat --listen --keep-open --send-only --max-conns=1 3307 -c \
	 						 "mariabackup --backup --slave-info --stream=xbstream --socket=/run/mysqld/mysqld.sock --user='root'"
						EOF
					]
					startup_probe {
					 	exec {
					 		command = ["pkill", "-f", "ncat"]
					 	}
					}
					volume_mount {
						name			 = "data"
						mount_path = "/var/lib/mysql"
						sub_path	 = "mysql"
					}
					volume_mount {
						name			 = "conf-d"
						mount_path = "/etc/mysql/conf.d"
					}
					volume_mount {
						name = "mysqld"
						mount_path = "/run/mysqld"
					}
					resources {
						requests = {
							"cpu"		= "100m"
							"memory" = "100Mi"
						}
					}
				}
				volume {
					name = "config-map"
					config_map {
						name = "mariadb"
					}
				}
				 volume {
					name = "conf-d"
					empty_dir {}
				}
				volume {
					name = "mysqld"
					empty_dir {}
				}
			}
		}
		volume_claim_template {
			metadata {
				name = "data"
			}
			spec {
				access_modes = ["ReadWriteOnce"]
				resources {
					requests = {
						"storage" = var.storage_size
					}
				}
			}
		}
	}
}
# resource "kubernetes_persistent_volume_claim" "mariadb" {
# 	metadata {
# 		namespace = var.namespace
# 		name = "data"
# 	}
# 	spec {
# 		access_modes = ["ReadWriteOnce"]
# 		resources {
# 			requests = {
# 				"storage" = var.storage_size
# 			}
# 		}
# 	}
# }
resource "kubernetes_horizontal_pod_autoscaler" "mariadb" {
	metadata {
		namespace = var.namespace
		name			= "mariadb"
	}
	spec {
		min_replicas = var.min_replicas
		max_replicas = var.max_replicas
		scale_target_ref {
			kind = "Deployment"
			name = "mariadb"
		}
		metric {
			type = "Resource"
			resource {
				name = "cpu"
				target {
					type								= "Utilization"
					average_utilization = "62"
				}
			}
		}
		metric {
			type = "Resource"
			resource {
				name = "memory"
				target {
					type								= "Utilization"
					average_utilization = "62"
				}
			}
		}
	}
}
