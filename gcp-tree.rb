#!/usr/bin/env ruby

# Amazingly, Google doesn't appear to provide a way to view all the resources that belong
# to a GCP organisation.
#
# This hacky script is my quick attempt to build that tool.
#
# USAGE
#
# First, authenticate with the gcloud tool:
#
#     gcloud auth login
#
# Then, run this script:
#
#     ./gcp-tree.rb
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

organisations = json_cmd("gcloud organizations list --format=json")

if organisations.size == 0
  fatal("No organisations found")
elsif organisations.size > 1
  fatal("Unable to process more than one organisation")
end

organisation = organisations.first
organisation_id = organisation.fetch("name").split("/").last

tree = GcpNode.new("Organisation: #{organisation['displayName']}")

projects = json_cmd("gcloud projects list --filter 'parent.id=#{organisation_id}' --format=json")

projects.each do |project|
  projectId = project.fetch("projectId")
  projectNode = GcpNode.new("project: #{project.fetch('name')} (#{projectId})")
  tree << projectNode

  # Google Compute Engine
  compute_instances = json_cmd("gcloud -q compute instances list --project #{projectId} --format=json")

  if compute_instances.any?
    productNode = GcpNode.new("Compute Engine")
    projectNode << productNode
    compute_instances.each do |instance|
      instanceName = instance.fetch("name")
      instanceType = instance.fetch("machineType").split("/").last
      instanceZone = instance.fetch("zone").split("/").last
      productNode << GcpNode.new("Instance name: #{instanceName} type: #{instanceType} zone: #{instanceZone}")
    end
  end

  # Cloud DNS
  managed_zones = json_cmd("gcloud -q dns managed-zones list --project #{projectId} --format=json")

  if managed_zones.any?
    productNode = GcpNode.new("Cloud DNS")
    projectNode << productNode
    managed_zones.each do |zone|
      zoneName = zone.fetch("dnsName")
      productNode << GcpNode.new("DNS Zone: #{zoneName}")
    end
  end

  # Google Kubernetes Engine
  clusters = json_cmd("gcloud -q container clusters list --project #{projectId} --format=json")

  if clusters.any?
    productNode = GcpNode.new("Google Kubernetes Engine")
    projectNode << productNode
    clusters.each do |cluster|
      clusterName = cluster.fetch("name")
      clusterZone = cluster.fetch("zone")
      clusterNodeCount = cluster.fetch("currentNodeCount")
      clusterMasterVersion = cluster.fetch("currentMasterVersion")
      productNode << GcpNode.new("Cluster name: #{clusterName} zone: #{clusterZone} nodes: #{clusterNodeCount} master-version: #{clusterMasterVersion}")
    end
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
