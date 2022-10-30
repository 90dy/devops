# cf. https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/
# cf. https://github.com/mariadb-corporation/MaxScale/blob/2.2/Documentation/Tutorials/MaxScale-Tutorial.md
# cf. https://github.com/mariadb-corporation/MaxScale/blob/2.2/Documentation/Tutorials/Read-Write-Splitting-Tutorial.md

variable "user" {
	type = string
	default = "root"
}
variable "password" {
	type = string
	default = "password"
}

variable "min_replicas" {
	type = number
	default = 2
}
variable "max_replicas" {
  type    = number
  default = 5
}
variable "storage_size" {
	type = string
	default = "1Gi"
}

# Permit external-dns to handle host
resource "kubernetes_ingress_v1" "mysql" {
  depends_on = [
    kubernetes_namespace.default
  ]
  metadata {
    namespace = "default"
    name      = "mysql"
  }
  spec {
    rule {
      host = "90dy.me"
    }
  }
}
# IngressRoute resource is custom to traefik
resource "kubernetes_manifest" "mysql" {
  depends_on = [
    kubernetes_namespace.default
  ]
  manifest = yamldecode(<<-EOF
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
  )
}
resource "kubernetes_config_map" "mariadb" {
  depends_on = [
    kubernetes_namespace.default
  ]
  metadata {
    namespace = "default"
    name      = "mariadb"
  }
  data = {
    "primary.cnf"  = <<-EOF
			# Apply this config only on the primary.
			[mariadb]
			log-bin
			EOF
    "replicas.cnf" = <<-EOF
			# Apply this config only on replicas.
			[mariadb]
			super-read-only
			EOF
    # Follow this tutorial:
    # https://github.com/mariadb-corporation/MaxScale/blob/2.2/Documentation/Tutorials/Read-Write-Splitting-Tutorial.md
    # also interesting: https://github.com/GusTheBusNG/MariaDB-and-Kubernetes/blob/master/master-slave/maxscale.yml
    "maxscale.cnf" = <<-EOF
			[maxscale]
			threads=auto

			${join("", [for id in range(0, var.max_replicas) :
				<<-EOF
					[dbserv${id}]
					type=server
					host=mariadb-${id}.mysql
					port=3306
					protocol=MariaDBBackend
				EOF
			])}

			[Splitter-Service]
			type=service
			router=readwritesplit
			servers=${join(", ", [for id in range(0, var.max_replicas) : "dbserv${id}"])}
			user=${var.user}
			password=${var.password}

			[Splitter-Listener]
			type=listener
			service=Splitter-Service
			protocol=MariaDBClient
			port=3306
			EOF
	}
}

# Headless service for stable DNS entries of StatefulSet members.
resource "kubernetes_service" "mysql" {
  depends_on = [
    kubernetes_config_map.mariadb
  ]
  metadata {
    namespace = "default"
    name      = "mysql"
  }
  spec {
    port {
      name = "maxscale"
      port = 3306
    }
    cluster_ip = "None"
    selector = {
      app = "mysql"
    }
  }
}

resource "kubernetes_stateful_set" "mariadb" {
	timeouts {
		create = "3m"
	}
  depends_on = [
    kubernetes_service.mysql,
    # kubernetes_service.mysql_read,
    kubernetes_config_map.mariadb,
  ]
  metadata {
    namespace = "default"
    name      = "mariadb"
    labels = {
      "app" = "mysql"
    }
  }
  spec {
    service_name = "mysql"
    replicas     = var.min_replicas
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
          name  = "init-mariadb"
          image = "mariadb:10.9"
          volume_mount {
            name       = "conf-d"
            mount_path = "/mnt/conf.d"
          }
          volume_mount {
            name       = "config-map"
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
          name  = "clone-mariadb"
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

							echo "TODO: find a faster method to install ncat"
							apt-get update \
								&& apt-get install -y ncat \
								&& apt-get clean autoclean \
								&& apt-get autoremove --yes \
								&& rm -rf /cat/lib/{apt,dpkg,cache,log}/

							echo "Clone data from previous peer."
							ncat --recv-only mariadb-$(($ordinal-1)).mysql 3307 | xbstream -x -C /var/lib/mysql

							echo "Prepare the backup."
							mariabackup --prepare --target-dir=/var/lib/mysql
							EOF
          ]
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
          volume_mount {
            name       = "conf-d"
            mount_path = "/etc/mysql/conf.d"
          }
        }
        container {
          name  = "maxscale"
          image = "mariadb/maxscale:22.08.2"
          port {
            name           = "maxscale"
            container_port = 3306
          }
          volume_mount {
            name = "config-map"
            mount_path = "/etc/maxscale.cnf"
						sub_path = "maxscale.cnf"
          }
        }
        container {
          name  = "mariadb"
          image = "mariadb:10.9"
          volume_mount {
            name       = "conf-d"
            mount_path = "/etc/mysql/conf.d"
          }
					volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
					volume_mount {
						name = "mysqld"
						mount_path = "/run/mysqld"
					}
          resources {
            requests = {
              "cpu"    = "500m"
              "memory" = "1Gi"
            }
          }
          liveness_probe {
            exec {
              command = ["mysqladmin", "ping"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }
          readiness_probe {
            exec {
              command = ["mysql", "-e", "SELECT 1"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
            timeout_seconds       = 1
          }
					startup_probe {
						exec {
              command = ["mysql", "-e",
								<<-EOF
									CREATE USER IF NOT EXISTS '${var.user}'@'%';
									ALTER USER '${var.user}'@'%' IDENTIFIED BY '${var.password}';
									GRANT SELECT ON mysql.user TO '${var.user}'@'%';
									GRANT SELECT ON mysql.db TO '${var.user}'@'%';
									GRANT SELECT ON mysql.tables_priv TO '${var.user}'@'%';
									GRANT SELECT ON mysql.roles_mapping TO '${var.user}'@'%';
									GRANT SHOW DATABASES ON *.* TO '${var.user}'@'%';

									-- MariaDB from 10.2.2 to 10.2.10 requires extra grants
									GRANT SELECT ON mysql.* TO '${var.user}'@'%';
								EOF
							]
						}
					}
        }
        container {
          name  = "mariabackup"
          image = "mariadb:10.9"
          port {
            name           = "mariabackup"
            container_port = 3307
          }
          command = [
            "bash",
            "-c",
            <<-EOF
	 						set -ex
	 						cd /var/lib/mysql

	 						echo "Determine binlog position of cloned data, if any."
	 						if [[ -f mariabackup_slave_info && "x$(<mariabackup_slave_info)" != "x" ]]; then
	 							echo "MariaBackup already generated a partial `CHANGE MASTER TO` query"
	 							echo "because we're cloning from an existing replica. (Need to remove the tailing semicolon!)"
	 							cat mariabackup_slave_info | sed -E 's/;$//g' > change_master_to.sql.in
	 							echo "Ignore mariabackup_binlog_info in this case (it's useless)."
	 							rm -f mariabackup_slave_info mariabackup_binlog_info
	 						elif [[ -f mariabackup_binlog_info ]]; then
	 							echo "We're cloning directly from primary. Parse binlog position."
	 							[[ `cat mariabackup_binlog_info` =~ ^(.*?)[[:space:]]+(.*?)$ ]] || exit 1
	 							rm -f mariabackup_binlog_info mariabackup_slave_info
	 							echo "CHANGE MASTER TO MASTER_LOG_FILE='$${BASH_REMATCH[1]}',\
	 							MASTER_LOG_POS=$${BASH_REMATCH[2]}" > change_master_to.sql.in
	 						fi

	 						echo "Check if we need to complete a clone by starting replication."
	 						if [[ -f change_master_to.sql.in ]]; then
	 							echo "Waiting for mysqld to be ready (accepting connections)"
								until mysql -e "SELECT 1"; do sleep 1; done

	 							echo "Initializing replication from clone position"
								mysql \
	 								-e "$(<change_master_to.sql.in), \
	 									MASTER_HOST='mariadb-0.mysql', \
	 									MASTER_USER='${var.user}', \
	 									MASTER_PASSWORD='${var.password}', \
	 									MASTER_CONNECT_RETRY=10; \
	 									START SLAVE;" || exit 1
	 							echo "In case of container restart, attempt this at-most-once."
	 							mv change_master_to.sql.in change_master_to.sql.orig
	 						fi

							echo "TODO: find a faster method to install ncat"
							apt-get update \
								&& apt-get install -y ncat \
								&& apt-get clean autoclean \
								&& apt-get autoremove --yes \
								&& rm -rf /cat/lib/{apt,dpkg,cache,log}/

	 						echo "Start a server to send backups when requested by peers."
	 						exec ncat --listen --keep-open --send-only --max-conns=1 3307 -c \
	 						 "mariabackup --backup --slave-info --stream=xbstream --socket=/run/mysqld/mysqld.sock --user='${var.user}'"
							EOF
          ]
				  startup_probe {
           	exec {
           	  command = ["pkill", "-f", "ncat"]
           	}
	        }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
          volume_mount {
            name       = "conf-d"
            mount_path = "/etc/mysql/conf.d"
          }
					volume_mount {
						name = "mysqld"
						mount_path = "/run/mysqld"
					}
          resources {
            requests = {
              "cpu"    = "100m"
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
				namespace = "default"
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

resource "kubernetes_horizontal_pod_autoscaler" "mariadb" {
  metadata {
    namespace = "default"
    name      = "mariadb"
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
          type                = "Utilization"
          average_utilization = "62"
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = "62"
        }
      }
    }
  }
}
