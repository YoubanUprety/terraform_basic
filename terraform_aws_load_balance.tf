# Terraform settings

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}


# variables.tf


variable "instance_name" {
  description = "Value of the Name tag for the EC2 instance"
  type        = string
  default     = "TerraformLearningEC2Instance"
}

variable "aws_region" { 
  default = "us-east-2"
  type  = string
   }


variable "vpc_id" {
  default = "vpc-0ac2a262f3630e4e1"
  type  = string
  }
variable "project_name" {
  default = "fastapi-hypercorn-app"
  type  = string
  }
variable "launch_type" { 
  default = "FARGATE"
  type  = string 
  }
variable "docker_image_name" {
  default = "191003624475.dkr.ecr.us-east-2.amazonaws.com/fastapi-hyper-ecr"
  type  = string
  }
variable "docker_image_revision" {
  default = "v1"
  type  = string
  }



# providers.tf


provider "aws" {
  region  = var.aws_region
}


# networking.tf
data "aws_vpc" "app_vpc" {
  id = var.vpc_id
}
data "aws_subnets" "app_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.app_vpc.id]
  }
}
data "aws_security_groups" "app_sg" {
  filter {
    name   = "group-name"
    values = ["launch-wizard-5"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.app_vpc.id]
  }
}


# cluster.tf
resource "aws_ecs_cluster" "app_cluster" {
  name = "${var.project_name}-cluster"
}


# service.tf

resource "aws_ecs_service" "app_service" {
  name        = "${var.project_name}-service"
  cluster     = aws_ecs_cluster.app_cluster.arn
  launch_type = var.launch_type

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 0
  desired_count                      = 2
  task_definition                    = aws_ecs_task_definition.django_app.arn

  network_configuration {
    assign_public_ip = true
    security_groups  = data.aws_security_groups.app_sg.ids
    subnets          = data.aws_subnets.app_subnet.ids
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app_alb_tg.id
    container_name   = var.project_name
    container_port   = 8000
  }
}



# Task definition

data "template_file" "django_app" {
  template = file("./task-definition.json")
  vars = {
    app_name       = var.project_name
    app_image      = "${var.docker_image_name}:${var.docker_image_revision}"
    app_port       = 8000
    fargate_cpu    = "256"
    fargate_memory = "512"
    aws_region     = var.aws_region
  }
}
resource "aws_ecs_task_definition" "django_app" {
  container_definitions    = data.template_file.django_app.rendered
  family                   = var.project_name
  requires_compatibilities = [var.launch_type]
  task_role_arn            = aws_iam_role.app_execution_role.arn
  execution_role_arn       = aws_iam_role.app_execution_role.arn

  cpu          = "256"
  memory       = "512"
  network_mode = "awsvpc"
}


# Load balancer

resource "aws_alb" "app_alb" {
  name            = "${var.project_name}-alb"
  subnets         = data.aws_subnets.app_subnet.ids
  security_groups = data.aws_security_groups.app_sg.ids
}
resource "aws_alb_target_group" "app_alb_tg" {
  name        = "${var.project_name}-alb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.app_vpc.id
  target_type = "ip"
  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "/"
    unhealthy_threshold = "2"
  }
}
resource "aws_alb_listener" "app_alb_listener" {
  load_balancer_arn = aws_alb.app_alb.id
  port              = 80
  protocol          = "HTTP"
  default_action {
    target_group_arn = aws_alb_target_group.app_alb_tg.id
    type             = "forward"
  }
}




# IAM roles

resource "aws_iam_role" "app_execution_role" {
  name               = "${var.project_name}-execution-role"
  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": [
          "ecs.amazonaws.com",
          "ecs-tasks.amazonaws.com"
        ]
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}


# output.tf

output "app_dns_lb" {
  description = "DNS load balancer"
  value       = aws_alb.app_alb.dns_name
}