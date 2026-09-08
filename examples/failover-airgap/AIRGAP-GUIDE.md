# Air-gap failover in AWS GovCloud - route-based VIP guide

This is the companion to [`examples/failover/GOVCLOUD-GUIDE.md`](../failover/GOVCLOUD-GUIDE.md).
Everything about staging the bucket, the admin secret, the key pair, the image lookup and the
clustering self-heal applies unchanged. This guide covers only what this template does
differently: **no public addresses, and a VIP that fails over across Availability Zones
by route rather than by Elastic IP.**

> ### ⚠️ Not yet lab-validated
> The templates lint clean and the CFE declaration follows F5's documented schema and
> examples, but this path has **not** been run end to end in GovCloud yet. Section 5 is the
> validation procedure. Run it in both failover directions and record the measured
> convergence time before this design goes in front of a customer.

## 1. Why the EIP-based template cannot do this

The `examples/failover` solution puts each BIG-IP in its own Availability Zone, so its own
external subnet. Its VIP is a **secondary private IP** on each device's external ENI:

| BIG-IP | AZ | External subnet | Self IP | VIP (secondary) |
|---|---|---|---|---|
| failover01 | AZ a | `10.0.0.0/24` | `10.0.0.11` | `10.0.0.101` |
| failover02 | AZ b | `10.0.4.0/24` | `10.0.4.11` | `10.0.4.101` |

A secondary private IP belongs to its subnet's CIDR. AWS will not assign `10.0.0.101` to an
ENI in `10.0.4.0/24`, so the two VIPs are two independent addresses, and the only thing CFE
can move between them is an **Elastic IP association**. Take the EIP away, as an air-gap
deployment must, and CFE has nothing to relocate. The stack deploys, the cluster forms,
`cloud-failover/inspect` looks healthy, and the VIP never moves. That is what this template
fixes.

## 2. How route-based failover works here

The VIP is an address **outside the VPC CIDR**, `externalVipAddress` (default
`10.99.0.100`), inside a prefix `externalVipCidr` (default `10.99.0.0/24`). Because the
prefix is not part of the VPC, AWS has no implicit route for it, so the template creates
one in every route table:

```
Route table (tagged f5_cloud_failover_label = cfeTag)
  Destination        Target
  10.99.0.0/24    →  eni-…  (failover01's external ENI, initially)
```

A client anywhere in the VPC sends to `10.99.0.100`; its subnet's route table sends the
packet to the active BIG-IP's external ENI; the BIG-IP answers because AS3 has bound a
virtual server to that address. On failover, CFE calls `ec2:ReplaceRoute` in each tagged
route table and points the prefix at the peer's ENI. One API call per table, no addressing
changes anywhere.

Five things have to line up for that to work, and the template does all five:

| Requirement | Where it is done |
|---|---|
| Route for the prefix in every route table clients use | `VipRoutePublic`, `VipRoutePrivateA`, `VipRoutePrivateB` in `failover-airgap.yaml` |
| Route tables tagged so CFE can find them **and** IAM lets CFE change them | `modules/network` parameter `routeTableFailoverTag` (set to `cfeTag`) |
| Source/destination checking **off** on both external ENIs, or AWS drops the traffic before BIG-IP sees it | `modules/bigip-standalone` parameter `disableSourceDestCheck` |
| `failoverRoutes` in the CFE declaration, with both external Self IPs as next hops | `bigip-configurations/runtime-init-conf-*-airgap.yaml`, values from instance tags |
| AS3 virtual server on the VIP address | same files, `Service_Address_01` |

The instance role already has what CFE needs. `solutionType: failover` provisions
`BigIpHighAvailabilityAccessRole`, which grants `ec2:ReplaceRoute`, `ec2:CreateRoute` and
`ec2:DescribeRouteTables`; the write actions are conditioned on the route table carrying
`f5_cloud_failover_label` = `cfeTag`, which the network tag satisfies.

## 3. Choosing the parameters

**`externalVipCidr` and `externalVipAddress`.** Pick a prefix that collides with nothing
reachable from the VPC: not the VPC CIDR, not peered VPCs, not on-premises ranges arriving
over Direct Connect, VPN or Transit Gateway. The address must be inside the prefix. The
same prefix is used for the route and for CFE's `scopingAddressRanges`; CFE's prefix
matching is exact, so do not try to route a `/32` and scope a `/24`.

**`provisionSsmAccess` (default `true`).** The BIG-IP management interfaces have no public
address, so you need a way in. The default deploys a small Amazon Linux jump host in the
BIG-IP management subnet, registered with AWS Systems Manager through the `ssm`,
`ssmmessages` and `ec2messages` interface endpoints. It has **no public IP, no inbound
security group rule and no SSH key** - the only way onto it is `aws ssm start-session`,
which is authorised by IAM and logged in CloudTrail. From your workstation you
port-forward *through* it to a BIG-IP management address (section 4a). BIG-IP itself
cannot run the SSM Agent, which is why the hop exists.

> **Check this before you create the stack.** The jump host resolves its image from an
> AWS-published SSM parameter. If that parameter is not present in your Region the nested
> stack fails at create time, which is an annoying way to lose a deployment window:
>
> ```bash
> aws ssm get-parameter --region "$REGION" \
>   --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
>   --query 'Parameter.Value' --output text
> ```
>
> If that returns an AMI ID, you are fine. If it errors, pass any AMI that has the SSM
> Agent installed and starting at boot (Amazon Linux 2 and 2023 both do, as do most
> hardened AL2023 images) as `ssmJumpCustomImageId`. Use `ssmJumpInstanceType` if
> `t3.micro` is unavailable in the Region.

**`provisionBastion` (default `false`).** The fallback for environments where Systems
Manager is not permitted: the repository's Linux bastion in the first external subnet
**with a public IP** and SSH open to `restrictedSrcAddressMgmt`. That is a public address
and an open port inside an air-gap design, and it is the first thing an assessor will find.
Use it deliberately or not at all. With both set to `false`, nothing in the VPC has a
public address and management must arrive over private connectivity.

**Everything else** is as in the GovCloud guide's parameter reference. The public-IP
toggles are gone because they have exactly one valid value here.

## 4. Deploy

Stage the bucket as in the GovCloud guide, including this directory, then create the stack
with `failover-airgap-parameters.json` (fill in the bucket, key, secret and source-address
values first). The BIG-IPs fetch their runtime-init configs from
`<artifactLocation>failover-airgap/bigip-configurations/` by default.

After `CREATE_COMPLETE`, the outputs tell you what to look at: `vipAddress`,
`vipRouteTableIds`, `bigIpExternalInterfaceId01/02`, `ssmJumpInstanceId`, and two
ready-to-paste port-forwarding commands, `ssmPortForwardBigIp01` and `ssmPortForwardBigIp02`.

### 4a. Reaching the BIG-IPs through Session Manager

Prerequisites on your workstation: the AWS CLI, the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
and an identity allowed `ssm:StartSession` on the jump instance and on the
`AWS-StartPortForwardingSessionToRemoteHost` document.

```bash
REGION=us-gov-west-1
JUMP=$(aws cloudformation describe-stacks --region "$REGION" --stack-name failover-airgap \
  --query "Stacks[0].Outputs[?OutputKey=='ssmJumpInstanceId'].OutputValue" --output text)
MGMT_01=10.0.1.11   # bigIpInstanceMgmtPrivateIp01 output
MGMT_02=10.0.5.11   # bigIpInstanceMgmtPrivateIp02 output

# GUI / REST: localhost:8443 -> BIG-IP A management 443 (the ssmPortForwardBigIp01 output is this command)
aws ssm start-session --region "$REGION" --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$MGMT_01\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}"
# then browse https://localhost:8443 and curl -sku admin:"$PW" https://localhost:8443/mgmt/...

# SSH: localhost:2222 -> BIG-IP A management 22
aws ssm start-session --region "$REGION" --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$MGMT_01\"],\"portNumber\":[\"22\"],\"localPortNumber\":[\"2222\"]}"
ssh -p 2222 admin@localhost

# A shell on the jump host itself - the place to curl the VIP from inside the VPC
aws ssm start-session --region "$REGION" --target "$JUMP"
```

Each `start-session` holds the terminal; run them in separate windows. Use `8444` /
`2223` for BIG-IP B, or just paste the `ssmPortForwardBigIp02` output.

**The GUI works through the tunnel.** With the first command running, browse
`https://localhost:8443`, accept the BIG-IP's self-signed certificate warning, and log in
as `admin` with the password from `bigIpSecretArn`. REST calls work the same way
(`curl -sku admin:"$PW" https://localhost:8443/mgmt/shared/cloud-failover/inspect`).

> **Session logging.** Session Manager can write every session's keystrokes to CloudWatch
> Logs or S3, which is materially better evidence for an ATO package than a bastion's
> syslog. It is an account-level Session Manager preference, not a stack resource, so this
> template does not configure it; enable it in Systems Manager → Session Manager →
> Preferences before the first customer-facing use.

## 5. Verifying - do this in both directions

Open a port-forward to each BIG-IP as in section 4a (or, if you chose the bastion,
`ssh -J ec2-user@<bastion> admin@<mgmt-ip>`), then:

```bash
REGION=us-gov-west-1
RTBS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name failover-airgap \
  --query "Stacks[0].Outputs[?OutputKey=='vipRouteTableIds'].OutputValue" --output text | tr ',' ' ')
ENI_01=...   # bigIpExternalInterfaceId01 output
ENI_02=...   # bigIpExternalInterfaceId02 output

# 1. Source/dest check must be False on both external ENIs
aws ec2 describe-network-interfaces --region "$REGION" --network-interface-ids "$ENI_01" "$ENI_02" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,SourceDestCheck]' --output text

# 2. Every route table must be tagged and carry the VIP route
aws ec2 describe-route-tables --region "$REGION" --route-table-ids $RTBS \
  --query 'RouteTables[].[RouteTableId,Tags[?Key==`f5_cloud_failover_label`].Value|[0],Routes[?DestinationCidrBlock==`10.99.0.0/24`].NetworkInterfaceId|[0]]' --output table

# 3. On each BIG-IP, CFE must report the route - "routes" must NOT be empty
curl -sku admin:"$PW" https://localhost/mgmt/shared/cloud-failover/inspect | python3 -m json.tool

# 4. On the STANDBY, a dry run shows what a failover would change
curl -sku admin:"$PW" -X POST -d '{"action":"dry-run"}' \
  https://localhost/mgmt/shared/cloud-failover/trigger | python3 -m json.tool

# 5. Fail over from the active device, and time the route change
tmsh run sys failover standby
watch -n2 "aws ec2 describe-route-tables --region $REGION --route-table-ids $RTBS \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==\`10.99.0.0/24\`].NetworkInterfaceId' --output text"

# 6. From a client in the VPC, the VIP must answer before and after. A Session Manager shell
#    on the jump host is the easiest client: aws ssm start-session --target "$JUMP"
#    With no back-end app deployed, the demo responder answers and names the device:
curl -sk https://10.99.0.100/ | grep -o 'failover0[12][.a-z]*'     # flips after step 5
```

Then fail back and repeat. IAM and endpoint problems sometimes surface on only one
instance. Record the time between step 5 and the route showing the new target; that is the
number a customer with an RTO needs.

### 5a. Showing it in a browser

Every AS3 declaration in this directory carries a `Demo_Responder` iRule. When the VIP's
pool has no active members - which is the case with `provisionExampleApp=false` - it
answers HTTP and HTTPS requests itself with a page that names the BIG-IP that served it,
the VIP address, the client address and the time, and refreshes itself every two seconds.
When the example app (or any real pool member) is present the rule returns immediately and
traffic is load balanced as normal, so it never has to be removed.

For a demo, forward a local port to the VIP through the jump host and leave the page open
while you fail over:

```bash
aws ssm start-session --region "$REGION" --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["10.99.0.100"],"portNumber":["443"],"localPortNumber":["9443"]}'
# browse https://localhost:9443 - "Served by failover02.local" becomes failover01.local
# a few seconds after "tmsh run sys failover standby" on the active device
```

The page turning over is the whole failover mechanism in one screen: the route moved,
the peer became active, and the client never changed the address it was talking to.

## 6. Two things to plan for

**Reachability beyond the VPC.** The template routes the VIP prefix inside the VPC only.
Clients arriving over Direct Connect, VPN or a Transit Gateway need `externalVipCidr`
propagated into *those* route tables. Straightforward, but it is a conversation with the
customer's network team and belongs in the design, not in testing.

**Convergence is slower than an EIP move.** Route table updates take longer to take effect
than an address reassociation. Plan on tens of seconds rather than a handful, and measure
it in step 5 before committing to an RTO.

## 7. Troubleshooting

**Route moves, VIP does not answer.** Source/dest check is still enabled on an external
ENI (step 1 above). The template disables it on the ENI resource, so if it is `True`
something recreated the interface outside the stack.

**`routes` is empty in `inspect`.** CFE found no tagged route table, or none with a route
for exactly `externalVipCidr`. Check step 2. A prefix mismatch between the route and the
scoping range is the usual cause when someone edits one side.

**`UnauthorizedOperation` on `ReplaceRoute` in `/var/log/restnoded/restnoded.log`.** The
route table has lost its `f5_cloud_failover_label` tag, or `cfeTag` was changed on one side
only. The IAM condition is on the tag value matching `cfeTag` exactly.

**`Failover initialization failed` / `ECONNREFUSED`.** The endpoints. This template always
provisions them, so check the security group on the interface endpoints and that the stack
Region matches the bucket Region, as in the GovCloud guide.

**Jump host never appears in Systems Manager (`start-session` says the target is not
connected).** The SSM Agent could not reach the `ssm` / `ssmmessages` / `ec2messages`
endpoints. Check that the three endpoints exist in the stack, that their security group
allows 443 from the VPC CIDR, and that private DNS is enabled on them. The agent needs a
few minutes after boot; `aws ssm describe-instance-information` lists it once registered.

**Everything else** - clustering, the self-heal, secrets, image lookup - is covered in the
GovCloud guide's troubleshooting section and applies unchanged.
