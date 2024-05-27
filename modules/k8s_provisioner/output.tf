output "control_plane_public_ip" {
  description = "Public IP address of the control plane instance"
  value       = aws_instance.control_plane.public_ip
}

output "worker_public_ips" {
  description = "Public IP addresses of the worker instances"
  value       = [for instance in aws_instance.worker : instance.public_ip]
}
