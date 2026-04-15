

# ----------------------------
# ECR (SINGLE REPO)
# ----------------------------
resource "aws_ecr_repository" "app_repo" {
  name = "webapp-dev"
}

# ----------------------------
# CLOUDWATCH LOGS
# ----------------------------
resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/webapp-dev"
  retention_in_days = 7
}

# ----------------------------
# IAM ROLE
# ----------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ----------------------------
# ECS CLUSTER
# ----------------------------
resource "aws_ecs_cluster" "cluster" {
  name = "ecs-cluster-dev"
}

# ----------------------------
# SECURITY GROUP
# ----------------------------
resource "aws_security_group" "task_sg" {
  name   = "task-sg-dev"
  vpc_id = data.aws_ssm_parameter.vpc_id.value

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------
# ALB
# ----------------------------
resource "aws_lb" "alb" {
  name               = "alb-dev"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.task_sg.id]

  subnets = split(",", data.aws_ssm_parameter.public_subnet_ids.value)
}

resource "aws_lb_target_group" "tg" {
  name        = "tg-dev"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value
  target_type = "ip"

  health_check {
    path = "/"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# ----------------------------
# TASK DEFINITION (ALL IN ONE TASK)
# ----------------------------
resource "aws_ecs_task_definition" "task" {
  family                   = "webapp-task-dev"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([

    # FRONTEND
    {
      name  = "frontend"
      image = "${aws_ecr_repository.app_repo.repository_url}:frontend"

      portMappings = [{
        containerPort = 80
      }]
    },

    # BACKEND
    {
      name  = "backend"
      image = "${aws_ecr_repository.app_repo.repository_url}:backend"

      portMappings = [{
        containerPort = 8080
      }]

      environment = [
        {
          name  = "DB_HOST"
          value = "127.0.0.1"
        },
        {
          name  = "DB_USER"
          value = "root"
        },
        {
          name  = "DB_PASSWORD"
          value = "root"
        },
        {
          name  = "DB_NAME"
          value = "expense"
        }
      ]
    },

    # MYSQL
    {
      name  = "mysql"
      image = "mysql:8"

      portMappings = [{
        containerPort = 3306
      }]

      environment = [
        {
          name  = "MYSQL_ROOT_PASSWORD"
          value = "root"
        },
        {
          name  = "MYSQL_DATABASE"
          value = "expense"
        }
      ]
    }
  ])
}

# ----------------------------
# ECS SERVICE
# ----------------------------
resource "aws_ecs_service" "service" {
  name            = "webapp-service-dev"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = split(",", data.aws_ssm_parameter.public_subnet_ids.value)
    security_groups  = [aws_security_group.task_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "frontend"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.listener]
}