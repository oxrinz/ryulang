<script lang="ts">
  import { Handle, Position, type NodeProps } from "@xyflow/svelte";

  let { data }: NodeProps = $props();
</script>

<div class="px-6 py-2 shadow-md rounded-md bg-white">
  <div class="flex">
    {data.label}
  </div>
  <Handle
    type="target"
    position={Position.Left}
    class="w-16 !bg-teal-500 rounded-none border-none"
  />
  <Handle
    type="source"
    position={Position.Right}
    class="w-16 !bg-teal-500 rounded-none border-none"
  />
</div>
