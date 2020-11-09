#!/usr/bin/env ruby

# Amazingly, AWS doesn't appear to provide a way to view all the resources that belong
# to a GCP organisation.
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
# Then, run this script with one or more regions:
#
#     ./aws-tree.rb us-east-1,us-west-1
#
# You should get output that looks something like:
#
#     Organisation: yob.id.au
#     ├─ project: unifi (unifi-1521373866918)
#     └─ project: trial project (macro-incline-193309)
#        ├─ Compute Engine
#        │  └─ Instance name: gke-cluster-foo-pool-b-22bb9925-xs5p type: n1-standard-4 zone: australia-southeast1-a
#        └─ Google Kubernetes Engine
#           └─ Cluster name: cluster-foo zone: australia-southeast1-a nodes: 1 master-version: 1.9.6-gke.0
#
# Resources we could add to the tree:
#
# * Datastore
# * Spanner
# * Bigtable
# * Networks
# * Cloud Functions
# * App Engine
# * Service Accounts?
# * Support Contracts
require 'json'
require 'open3'

def json_cmd(cmd)
  stdout, stderr, status = Open3.capture3(cmd)

  if status.success?
    JSON.parse(stdout)
  else
    []
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

regions = ARGV[0]
if regions.nil?
  fatal("USAGE: aws-tree.rb <regions>")
end

regions = regions.split(",")

caller_identity = json_cmd("aws sts get-caller-identity --output=json")
account_id = caller_identity.fetch("Account")

account_details = json_cmd("aws organizations describe-account --account-id=#{account_id} --output=json")

tree = GcpNode.new("Account: #{account_details.dig("Account", "Name")} (#{account_id})")

regions.each do |region|

  regionNode = GcpNode.new("region: #{region}")
  tree << regionNode

  # EC2
  result = json_cmd("aws ec2 describe-instances --filters Name=instance-state-name,Values=running --region=#{region} --output=json")
  compute_instances = result.fetch("Reservations").map { |res| res.fetch("Instances") }.flatten
  if compute_instances.any?
    productNode = GcpNode.new("EC2")
    regionNode << productNode
    compute_instances.each do |instance|
      instanceName = instance.fetch("Tags", []).detect { |row| row["Key"] == "Name" }.fetch("Value", "")
      instanceId = instance.fetch("InstanceId")
      instanceType = instance.fetch("InstanceType")
      instanceZone = instance.fetch("Placement").fetch("AvailabilityZone")
      externalIp = instance.fetch("PublicIpAddress", "")
      productNode << GcpNode.new("Compute Instance name: #{instanceName} id: #{instanceId} type: #{instanceType} zone: #{instanceZone} IP: #{externalIp}")
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
