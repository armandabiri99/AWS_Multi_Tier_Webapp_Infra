output "alb_dns" { value = aws_lb.alb.dns_name }

output "rds_proxy_writer_endpoint" {
  value       = aws_db_proxy.mysql.endpoint
  description = "Use for WRITES (and reads if app can't split)."
}

output "rds_proxy_reader_endpoint" {
  value       = aws_db_proxy_endpoint.reader.endpoint
  description = "Use for READS (load balanced across replicas)."
}