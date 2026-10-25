resource "aws_ecr_repository" "app" {
  name                 = "${local.name}/trades-app"
  image_tag_mutability = "IMMUTABLE" # a tag (git SHA) always means the same image
  force_delete         = true        # destroy succeeds even with images present

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
