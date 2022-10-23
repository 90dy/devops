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
apiVersion: "traefik.containo.us/v1alpha1"
kind: "IngressRouteTCP"
metadata:
  namespace: "default"
  name: "mysql"
spec:
  entryPoints: ["mysql"]
  routes:
  - services:
    - name: "mysql"
      port: 3306
    match: "HostSNI(`90dy.me`)"
		EOF
  )
}
resource "kubernetes_config_map" "mysql" {
  depends_on = [
    kubernetes_namespace.default
  ]
  metadata {
    namespace = "default"
    name      = "mysql"
  }
  data = {
    "primary.cnf"  = <<-EOF
			# Apply this config only on the primary.
	 		[mysqld]
			log-bin
			EOF
    "replicas.cnf" = <<-EOF
			# Apply this config only on replicas.
			[mysqld]
			super-read-only
			EOF
  }
}
# Headless service for stable DNS entries of StatefulSet members.
resource "kubernetes_service" "mysql" {
  depends_on = [
    kubernetes_config_map.mysql
  ]
  metadata {
    namespace = "default"
    name      = "mysql"
  }
  spec {
    port {
      name = "mysql"
      port = 3306
    }
    cluster_ip = "None"
    selector = {
      app = "mysql"
    }
  }
}
# Client service for connecting to any MySQL instance for reads.
# For writes, you must instead connect to the primary: mysql-0.mysql.
resource "kubernetes_service" "mysql_read" {
  depends_on = [
    kubernetes_config_map.mysql
  ]
  metadata {
    namespace = "default"
    name      = "mysql-read"
    labels = {
      "app"    = "mysql"
      readonly = "true"

    }
  }

  spec {
    port {
      name = "mysql"
      port = 3306
    }
    selector = {
      app = "mysql"
    }
  }

}
resource "kubernetes_stateful_set" "mysql" {
  depends_on = [
    kubernetes_service.mysql,
    kubernetes_service.mysql_read,
    kubernetes_config_map.mysql,
  ]
  metadata {
    namespace = "default"
    name      = "mysql"
    labels = {
      "app" = "mysql"
    }
  }
  spec {
    service_name = "mysql"
    replicas     = 1
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
          name  = "init-mysql"
          image = "mariadb:10.9"
          command = [
            "bash",
            "-c",
            <<-EOF
					 	 	set -ex
					 	 	# Generate mysql server-id from pod ordinal index.
					 	 	[[ $HOSTNAME =~ -([0-9]+)$ ]] || exit 1
					 	 	ordinal=$${BASH_REMATCH[1]}
					 	 	echo [mysqld] > /mnt/conf.d/server-id.cnf
					 	 	# Add an offset to avoid reserved server-id=0 value.
					 	 	echo server-id=$((100 + $ordinal)) >> /mnt/conf.d/server-id.cnf
					 	 	# Copy appropriate conf.d files from config-map to emptyDir.
					 	 	if [[ $ordinal -eq 0 ]]; then
					 	 		cp /mnt/config-map/primary.cnf /mnt/conf.d/
					 	 	else
					 	 		cp /mnt/config-map/replica.cnf /mnt/conf.d/
					 	 	fi
							EOF
          ]
          volume_mount {
            name       = "conf"
            mount_path = "/mnt/conf.d"
          }
          volume_mount {
            name       = "config-map"
            mount_path = "/mnt/config-map"
          }
        }
        init_container {
          name  = "clone-mysql"
          image = "gcr.io/google-samples/xtrabackup:1.0"
          command = [
            "bash",
            "-c",
            <<-EOF
							set -ex
							# Skip the clone if data already exists.
							[[ -d /var/lib/mysql/mysql ]] && exit 0
	 						# Skip the clone on primary (ordinal index 0).
							[[ `hostname` =~ -([0-9]+)$ ]] || exit 1
							ordinal=$${BASH_REMATCH[1]}
							[[ $ordinal -eq 0 ]] && exit 0
							# Clone data from previous peer.
							ncat --recv-only mysql-$(($ordinal-1)).mysql 3307 | xbstream -x -C /var/lib/mysql
							# Prepare the backup.
							xtrabackup --prepare --target-dir=/var/lib/mysql
							EOF
          ]
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/mysql/conf.d"
          }
        }
        container {
          name  = "mysql"
          image = "mariadb:10.9"
          env {
            name  = "MYSQL_ALLOW_EMPTY_PASSWORD"
            value = "1"
          }
          port {
            name           = "mysql"
            container_port = 3306
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/mysql/conf.d"
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
              command = ["mysql", "-h", "127.0.0.1", "-e", "SELECT 1"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
            timeout_seconds       = 1
          }
        }
        container {
          name  = "xtrabackup"
          image = "gcr.io/google-samples/xtrabackup:1.0"
          port {
            name           = "xtrabackup"
            container_port = 3307
          }
          command = [
            "bash",
            "-c",
            <<-EOF
	 						set -ex
	 						cd /var/lib/mysql

	 						# Determine binlog position of cloned data, if any.
	 						if [[ -f xtrabackup_slave_info && "x$(<xtrabackup_slave_info)" != "x" ]]; then
	 							# XtraBackup already generated a partial "CHANGE MASTER TO" query
	 							# because we're cloning from an existing replica. (Need to remove the tailing semicolon!)
	 							cat xtrabackup_slave_info | sed -E 's/;$//g' > change_master_to.sql.in
	 							# Ignore xtrabackup_binlog_info in this case (it's useless).
	 							rm -f xtrabackup_slave_info xtrabackup_binlog_info
	 						elif [[ -f xtrabackup_binlog_info ]]; then
	 							# We're cloning directly from primary. Parse binlog position.
	 							[[ `cat xtrabackup_binlog_info` =~ ^(.*?)[[:space:]]+(.*?)$ ]] || exit 1
	 							rm -f xtrabackup_binlog_info xtrabackup_slave_info
	 							echo "CHANGE MASTER TO MASTER_LOG_FILE='$${BASH_REMATCH[1]}',\
	 							MASTER_LOG_POS=$${BASH_REMATCH[2]}" > change_master_to.sql.in
	 						fi

	 						# Check if we need to complete a clone by starting replication.
	 						if [[ -f change_master_to.sql.in ]]; then
	 						 echo "Waiting for mysqld to be ready (accepting connections)"
	 						 until mysql -h 127.0.0.1 -e "SELECT 1"; do sleep 1; done

	 						 echo "Initializing replication from clone position"
	 						 mysql -h 127.0.0.1 \
	 									 -e "$(<change_master_to.sql.in), \
	 													 MASTER_HOST='mysql-0.mysql', \
	 													 MASTER_USER='root', \
	 													 MASTER_PASSWORD='', \
	 													 MASTER_CONNECT_RETRY=10; \
	 												 START SLAVE;" || exit 1
	 						 # In case of container restart, attempt this at-most-once.
	 						 mv change_master_to.sql.in change_master_to.sql.orig
	 						fi

	 						# Start a server to send backups when requested by peers.
	 						exec ncat --listen --keep-open --send-only --max-conns=1 3307 -c \
	 						 "xtrabackup --backup --slave-info --stream=xbstream --host=127.0.0.1 --user=root"
							EOF
          ]
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = "mysql"
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/mysql/conf.d"
          }
          resources {
            requests = {
              "cpu"    = "100m"
              "memory" = "100Mi"
            }
          }
        }
        volume {
          name = "conf"
          empty_dir {

          }
        }
        volume {
          name = "config-map"
          config_map {
            name = "mysql"
          }
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
            "storage" = "10Gi"
          }
        }
      }
    }
  }
}
resource "kubernetes_horizontal_pod_autoscaler" "mysql" {
  metadata {
    namespace = "default"
    name      = "mysql"
  }
  spec {
    min_replicas = 1
    max_replicas = 5
    scale_target_ref {
      kind = "StatefulSet"
      name = "mysql"
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
