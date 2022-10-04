#!/usr/bin/env ruby

# Amazingly, AWS doesn't appear to provide a way to view all the resources that belong
# to an AWS account.
#
# This hacky script is my quick attempt to build that tool. It's a good fit for small orgs with a
# modest number of projects and resources, but it's not Enterprise Scale.
#
# USAGE
#
# First, authenticate with the aws tool (skip this step if you're using aws-vault):
#
#     aws configure
#
# Then, run this script:
#
#     ./aws-tree.rb
#
# ... or, with aws-vault:
#
#     aws-vault exec <profile-name> -- ./aws-tree.rb
#
# You should get output that looks something like:
#
#      Account: Foo (012345678912)
#      ├─ region: us-east-1 30-day cost: $95.46
#      │  └─ EC2
#      │     ├─ Compute Instance name: foo-bastion id: i-23249ec type: t2.medium zone: us-east-1d IP: 1.2.3.4
#      │     └─ Compute Instance name: bar id: i-123123ad55 type: m5.large zone: us-east-1d IP:
#      ├─ region: us-west-1 30-day cost: $2.50
#      └─ S3
#         ├─ Bucket foo
#         └─ Bucket bar
#

require 'json'
require 'open3'
require 'time'
require 'bigdecimal'

def json_cmd(cmd)
  stdout, stderr, status = Open3.capture3(cmd)

  if status.success?
    JSON.parse(stdout)
  else
    raise stderr.inspect
  end
rescue JSON::ParserError
  []
end

def newline_cmd(cmd)
  stdout, stderr, status = Open3.capture3(cmd)

  if status.success?
    stdout.split("\n")
  else
    []
  end
rescue JSON::ParserError
  []
end

def fatal(msg)
  $stderr.puts msg
  exit(1)
end

def format_date(date)
  return nil if date.nil?

  Time.iso8601(date).strftime("%Y-%m-%d")
end

class AwsCostSummary

  attr_reader :regions

  def initialize(data)
    @regions = process_data(data)
  end

  def each_significant_region(&block)
    @regions.to_a.select { |region, cost|
      cost > 1
    }.reject { |region, _|
      region == "global" || region == "NoRegion"
    }.sort_by { |region, _|
      region
    }.each { |region, cost|
      yield region, cost
    }
  end

  private

  def process_data(data)
    regions = Hash.new(BigDecimal("0"))
    data.fetch("ResultsByTime", []).each do |time_data|
      time_data.fetch("Groups", []).each do |time_region_data|
        region = time_region_data.fetch("Keys",[]).first
        cost = BigDecimal(time_region_data.dig("Metrics","BlendedCost","Amount"))
        regions[region] += cost
      end
    end
    regions
  end
end

class GcpNode
  attr_reader :label, :children

  def initialize(label)
    @label = label
    @children = []
  end

  def <<(kid)
    @children << kid
  end
end

today = Time.now
thirty_days_ago = Time.now - (60 * 60 * 24 * 30)

costs_per_region = json_cmd("aws ce get-cost-and-usage --time-period 'Start=#{thirty_days_ago.strftime('%Y-%m-%d')},End=#{today.strftime('%Y-%m-%d')}' --granularity=DAILY --metrics BlendedCost --group-by Type=DIMENSION,Key=REGION")
summary = AwsCostSummary.new(costs_per_region)

caller_identity = json_cmd("aws sts get-caller-identity --output=json")
account_id = caller_identity.fetch("Account")

account_aliases = json_cmd("aws iam list-account-aliases --output=json")
aliases = account_aliases.fetch("AccountAliases", ["unknown"]).join(",")

tree = GcpNode.new("Account: #{aliases} (#{account_id})")

summary.each_significant_region do |region, cost|
  regionNode = GcpNode.new("region: #{region} 30-day cost: $#{cost.round(2).to_s('F')}")
  tree << regionNode

  # EC2
  result = json_cmd("aws ec2 describe-instances --filters Name=instance-state-name,Values=running --region=#{region} --output=json")
  compute_instances = result.fetch("Reservations",[]).map { |res| res.fetch("Instances") }.flatten
  if compute_instances.any?
    productNode = GcpNode.new("EC2")
    regionNode << productNode
    compute_instances.each do |instance|
      instanceName = instance.fetch("Tags", []).detect { |row| row["Key"] == "Name" }&.fetch("Value", "") || ""
      instanceId = instance.fetch("InstanceId")
      instanceType = instance.fetch("InstanceType")
      instanceZone = instance.fetch("Placement").fetch("AvailabilityZone")
      externalIp = instance.fetch("PublicIpAddress", "")
      launchTime = format_date(instance.fetch("LaunchTime", nil))
      productNode << GcpNode.new("Compute Instance name: #{instanceName} id: #{instanceId} type: #{instanceType} zone: #{instanceZone} IP: #{externalIp} launchDate: #{launchTime}")
    end
  end

  # Elastic Load Balancers
  result = json_cmd("aws elbv2 describe-load-balancers --region=#{region} --output=json")
  lbs = result.fetch("LoadBalancers")
  if lbs.any?
    productNode = GcpNode.new("Elastic Load Balancers")
    regionNode << productNode
    lbs.each do |lb|
      lbName = lb.fetch("LoadBalancerName")
      lbDns = lb.fetch("DNSName")
      lbType = lb.fetch("Type")
      lbZones = lb.fetch("AvailabilityZones", []).map { |zone| zone.fetch("ZoneName") }.join(",")
      createdTime = format_date(lb.fetch("CreatedTime", nil))
      productNode << GcpNode.new("Load Balancer #{lbName} type: #{lbType} DNS: #{lbDns} zones: #{lbZones} created_at: #{createdTime}")
    end
  end

  # RDS
  result = json_cmd("aws rds describe-db-instances --region=#{region} --output=json")
  instances = result.fetch("DBInstances")
  if instances.any?
    productNode = GcpNode.new("RDS")
    regionNode << productNode
    instances.each do |instance|
      instanceId = instance.fetch("DBInstanceIdentifier")
      instanceType = instance.fetch("DBInstanceClass")
      instanceEngine = instance.fetch("Engine")
      instanceEngineVersion = instance.fetch("EngineVersion")
      instanceZone = instance.fetch("AvailabilityZone")
      instanceZoneSecondary = instance.fetch("SecondaryAvailabilityZone", "-")
      productNode << GcpNode.new("Database #{instanceId} engine: #{instanceEngine} #{instanceEngineVersion} type: #{instanceType} zone: #{instanceZone}/#{instanceZoneSecondary}")
    end
  end

  # Cloud Formation
  result = json_cmd("aws cloudformation list-stacks --region=#{region} --output=json")
  stacks = result.fetch("StackSummaries")
  if stacks.any?
    productNode = GcpNode.new("Cloudformation")
    regionNode << productNode
    stacks.reject { |stack|
      stack.fetch("StackStatus") == "DELETE_COMPLETE"
    }.each do |stack|
      stackName = stack.fetch("StackName")
      stackStatus = stack.fetch("StackStatus")
      creation_time = format_date(stack.fetch("CreationTime", nil))
      productNode << GcpNode.new("Stack name: #{stackName} status: #{stackStatus} creation_time: #{creation_time}")
    end
  end

  # Elastic IP addresses
  result = json_cmd("aws ec2 describe-addresses --region=#{region} --output=json")
  addresses = result.fetch("Addresses")
  if addresses.any?
    productNode = GcpNode.new("Elastic IPs")
    regionNode << productNode
    addresses.each do |address|
      ip = address.fetch("PublicIp")
      productNode << GcpNode.new("Elastic IP #{ip}")
    end
  end

  # ECS Clusters
  result = json_cmd("aws ecs list-clusters --region=#{region} --output=json")
  arns = result.fetch("clusterArns")
  if arns.any?
    productNode = GcpNode.new("ECS Clusters")
    regionNode << productNode
    arns.each do |arn|
      cluster = json_cmd("aws ecs describe-clusters --cluster='#{arn}' --region=#{region} --output=json").fetch("clusters", []).first
      name = cluster.fetch("clusterName")
      serviceCount = cluster.fetch("activeServicesCount")
      runningTaskCount = cluster.fetch("runningTasksCount")
      productNode << GcpNode.new("ECS Cluster name: #{name} services: #{serviceCount} running-tasks: #{runningTaskCount}")
    end
  end

  # EKS Clusters
  result = json_cmd("aws eks list-clusters --region=#{region} --output=json")
  names = result.fetch("clusters")
  if names.any?
    productNode = GcpNode.new("EKS Clusters")
    regionNode << productNode
    names.each do |name|
      cluster = json_cmd("aws eks describe-cluster --name='#{name}' --region=#{region} --output=json").fetch("cluster", {})
      puts cluster.inspect
      name = cluster.fetch("name")
      version = cluster.fetch("version")
      productNode << GcpNode.new("EKS Cluster name: #{name} version: #{version}")
    end
  end

  # Lambda functions
  result = json_cmd("aws lambda list-functions --region=#{region} --output=json")
  functions = result.fetch("Functions")
  if functions.any?
    productNode = GcpNode.new("Lambda")
    regionNode << productNode
    functions.each do |function|
      name = function.fetch("FunctionName")
      runtime = function.fetch("Runtime")
      updated_at = format_date(function.fetch("LastModified", nil))
      productNode << GcpNode.new("Function name: #{name} runtime: #{runtime} updated-at: #{updated_at}")
    end
  end

  # VPCs
  result = json_cmd("aws ec2 describe-vpcs --region=#{region} --output=json")
  vpcs = result.fetch("Vpcs")
  if vpcs.any?
    productNode = GcpNode.new("VPCs")
    regionNode << productNode
    vpcs.each do |vpc|
      name = vpc.fetch("Tags", []).detect { |row| row["Key"] == "Name" }&.fetch("Value", "") || ""
      cidr = vpc.fetch("CidrBlock")
      productNode << GcpNode.new("VPC name: #{name} cidr: #{cidr}")
    end
  end

  # Intenet Gateways
  result = json_cmd("aws ec2 describe-internet-gateways --region=#{region} --output=json")
  gateways = result.fetch("InternetGateways")
  if gateways.any?
    productNode = GcpNode.new("Internet Gateways")
    regionNode << productNode
    gateways.each do |gateway|
      name = gateway.fetch("Tags", []).detect { |row| row["Key"] == "Name" }&.fetch("Value", "") || ""
      productNode << GcpNode.new("Internet Gateway name: #{name}")
    end
  end

  # NAT Gateways
  result = json_cmd("aws ec2 describe-nat-gateways --region=#{region} --output=json")
  gateways = result.fetch("NatGateways")
  if gateways.any?
    productNode = GcpNode.new("NAT GAteways")
    regionNode << productNode
    gateways.each do |gateway|
      creation_time = format_date(gateway.fetch("CreateTime", nil))
      productNode << GcpNode.new("NAT Gateway created-at: #{creation_time}")
    end
  end
end

# S3
buckets = newline_cmd("aws s3 ls")

if buckets.any?
  productNode = GcpNode.new("S3")
  tree << productNode
  buckets.each do |bucket|
    bucketName = bucket.split(" ").last
    productNode << GcpNode.new("Bucket #{bucketName}")
  end
end

# Route53 Hosted Zones
result = json_cmd("aws route53 list-hosted-zones --output=json")
zones = result.fetch("HostedZones")
if zones.any?
  productNode = GcpNode.new("Route53 Hosted Zones")
  tree << productNode
  zones.each do |zone|
    name = zone.fetch("Name")
    productNode << GcpNode.new("Zone #{name}")
  end
end

def print_node(node, ancestors_last: [])
  root_node = ancestors_last.empty?
  if root_node
    indent = ""
  else
    indent = ancestors_last.slice(0...-1).inject("") { |accum, last|
      if last
        accum += "   "
      else
        accum += "│  "
      end
    }
    if ancestors_last.last
      indent += "└─ "
    else
      indent += "├─ "
    end
  end
  puts "#{indent}#{node.label}"
  node.children.each do |child|
    print_node(child, ancestors_last: ancestors_last + [node.children.last == child])
  end
end

print_node(tree)
