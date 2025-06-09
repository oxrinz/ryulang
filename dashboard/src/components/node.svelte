<script lang="ts">
  import { Handle, Position, useEdges, type NodeProps } from "@xyflow/svelte";

  let { data }: NodeProps = $props();
</script>

<div class="px-6 py-2 shadow-md rounded-md bg-white">
  <div class="flex">
    {data.label}
  </div>
    <Handle
      type="source"
      position={Position.Left}
      class="w-16 !bg-neutral-500 rounded-none border-none"
      isConnectable={false}
    />

    <Handle
      type="target"
      position={Position.Right}
      class="w-16 !bg-neutral-500 rounded-none border-none"
      isConnectable={false}
    />
  </div>
