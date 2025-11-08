output "alb_dns" { value = aws_lb.alb.dns_name }

output "rds_proxy_endpoint" {
  value       = aws_db_proxy.mysql.endpoint
  description = "RDS Proxy endpoint for database connections (use for both reads and writes)"
}

# Note: READ_ONLY endpoint removed because RDS Proxy doesn't support read replicas
# for standalone RDS instances (only works with Aurora clusters)
# output "rds_proxy_reader_endpoint" {
#   value       = aws_db_proxy_endpoint.reader.endpoint
#   description = "Use for READS (load balanced across replicas)."
# }