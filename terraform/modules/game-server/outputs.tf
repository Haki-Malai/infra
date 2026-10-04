output "instance_id" { value = aws_instance.game.id }
output "instance_arn" { value = aws_instance.game.arn }
output "hostname" { value = var.hostname }
output "log_group" { value = aws_cloudwatch_log_group.game.name }
output "initial_stop_id" { value = aws_ec2_instance_state.initial_stop.id }
