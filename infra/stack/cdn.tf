# Public HTTPS entry: CloudFront (default *.cloudfront.net certificate) with a
# VPC origin to the internal ALB, which stays private. Dynamic HTML and API
# responses are never cached; static assets are.
resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = "${var.project}-internal-alb"
    arn                    = aws_lb.internal.arn
    http_port              = local.alb_port
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# CloudFront creates this service-managed group in the VPC for the origin's
# network interfaces; only it may reach the ALB from outside the tasks.
data "aws_security_group" "cloudfront_vpc_origin" {
  vpc_id = aws_vpc.main.id
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }
  depends_on = [aws_cloudfront_vpc_origin.alb]
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin.id
  ip_protocol                  = "tcp"
  from_port                    = local.alb_port
  to_port                      = local.alb_port
  description                  = "CloudFront VPC origin"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

locals {
  origin_id     = "internal-alb"
  static_paths  = ["/stylesheets/*", "/images/*"]
  dynamic_paths = ["/api", "/api/*"]
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  comment         = "${var.project} public entry"
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = local.origin_id
    domain_name = aws_lb.internal.dns_name

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.alb.id
      origin_read_timeout      = 10
      origin_keepalive_timeout = 5
    }
  }

  # Dynamic HTML (the page shows fresh database time per request).
  default_cache_behavior {
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.dynamic_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = local.origin_id
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD"]
      cached_methods             = ["GET", "HEAD"]
      cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
      compress                   = true
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.static_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = local.origin_id
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD"]
      cached_methods             = ["GET", "HEAD"]
      cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
      compress                   = true
    }
  }

  # Never cache origin errors: after an outage the next request reaches the
  # recovered origin instead of a cached 5xx (CloudFront's default is 10 s).
  dynamic "custom_error_response" {
    for_each = [500, 502, 503, 504]
    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # No custom domain: with the default *.cloudfront.net certificate AWS fixes
  # the minimum viewer protocol at TLSv1 (clients still negotiate TLS 1.2/1.3).
  # A stricter minimum needs a custom domain with an ACM certificate.
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }

  depends_on = [aws_vpc_security_group_ingress_rule.alb_from_cloudfront]
}

# Access logs to CloudWatch Logs (CloudFront log delivery runs in us-east-1).
resource "aws_cloudwatch_log_group" "cdn" {
  name              = "/aws/cloudfront/${var.project}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_delivery_source" "cdn" {
  name         = "${var.project}-cdn"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.main.arn
}

resource "aws_cloudwatch_log_delivery_destination" "cdn" {
  name          = "${var.project}-cdn-logs"
  output_format = "json"
  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.cdn.arn
  }
}

resource "aws_cloudwatch_log_delivery" "cdn" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cdn.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cdn.arn
}
